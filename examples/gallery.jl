# A runnable showcase of MCMCProgress: one scene per phase kind, a scene that
# runs several chains through all three kinds in sequence, a scene for each of
# the three endings a run can have, and Term's spinner styles side by side.
# Every scene runs through whichever backend is asked for on the command line,
# so the three backends can be compared against each other.
#
# The sampler is fake: it sleeps for a short, randomised interval per step, so
# every scene takes a few seconds.
#
# Run `julia --project=examples examples/gallery.jl --help` for usage.

using MCMCProgress
using Term
using ProgressLogging
using TerminalLoggers: TerminalLogger
using Logging: with_logger

# ------------------------------------------------------------------ sampler --

const STEP_SECONDS = 0.03

# Sleep for `seconds`, varied randomly by up to 30% either way.
fake_step(seconds::Real=STEP_SECONDS) = sleep(seconds * (0.7 + 0.6 * rand()))

# Run a determinate phase called `name` on chain `c` to completion, from
# position 0 up to `total`.
function run_determinate!(c, name::AbstractString, total::Integer; step=STEP_SECONDS)
    p = open_phase!(c, name, Determinate(total))
    for i in 1:total
        fake_step(step)
        advance!(p, i)
    end
    close_phase!(p)
    return nothing
end

# Run a counting phase called `name` on chain `c` for `n` steps. The phase is
# not told `n`.
function run_counting!(c, name::AbstractString, n::Integer; step=STEP_SECONDS)
    p = open_phase!(c, name, Counting())
    for i in 1:n
        fake_step(step)
        advance!(p, i)
    end
    close_phase!(p)
    return nothing
end

# Run a binary phase called `name` on chain `c` for about `seconds` before
# closing it. A binary phase has no position, so there is nothing to advance.
function run_binary!(c, name::AbstractString, seconds::Real; step=STEP_SECONDS)
    p = open_phase!(c, name, Binary())
    for _ in 1:max(1, round(Int, seconds/step))
        fake_step(step)
    end
    close_phase!(p)
    return nothing
end

# ------------------------------------------------------------------- scenes --

function scene_binary(backend)
    progress(; label="A binary phase", nchains=1, backend) do run
        run_binary!(chain_at(run, 1), "Connecting", 1.5)
    end
    return nothing
end

# 250 steps, because the plain-text backend writes a counting phase's line only
# every hundred positions.
function scene_counting(backend)
    progress(; label="A counting phase", nchains=1, backend) do run
        run_counting!(chain_at(run, 1), "Warmup", 250; step=0.012)
    end
    return nothing
end

function scene_determinate(backend)
    progress(; label="A determinate phase", nchains=1, backend) do run
        run_determinate!(chain_at(run, 1), "Sampling", 60)
    end
    return nothing
end

# Several chains at once, each moving through a binary, a counting, then a
# determinate phase: connecting, an adaptive warmup of unknown length, then a
# fixed number of draws.
function scene_fullrun(backend)
    nchains = 3
    progress(; label="Sampling mymodel", nchains, backend) do run
        @sync for j in 1:nchains
            Threads.@spawn begin
                c = chain_at(run, j)
                run_binary!(c, "Connecting", 0.8)
                run_counting!(c, "Warmup", 25)
                run_determinate!(c, "Sampling", 50)
            end
        end
    end
    return nothing
end

# Two chains, both run to completion: the run ends `finished`.
function scene_finished(backend)
    progress(; label="A run that finishes", nchains=2, backend) do run
        run_determinate!(chain_at(run, 1), "Sampling", 30)
        run_determinate!(chain_at(run, 2), "Sampling", 30)
    end
    return nothing
end

# Chain 2 is mid-phase when the body throws, so both chains end `failed` and the
# teardown closes chain 2's phase.
function scene_failed(backend)
    progress(; label="A run that fails", nchains=2, backend) do run
        run_determinate!(chain_at(run, 1), "Sampling", 30)
        p = open_phase!(chain_at(run, 2), "Sampling", Determinate(30))
        for i in 1:10
            fake_step()
            advance!(p, i)
        end
        error("the sampler encountered a numerical problem")
    end
    return nothing
end

# The same shape as `scene_failed`, but raises `InterruptException` instead of an
# ordinary error, which is what Ctrl-C delivers.
function scene_interrupted(backend)
    progress(; label="A run that is interrupted", nchains=2, backend) do run
        run_determinate!(chain_at(run, 1), "Sampling", 20)
        p = open_phase!(chain_at(run, 2), "Sampling", Determinate(30))
        for i in 1:8
            fake_step()
            advance!(p, i)
        end
        throw(InterruptException())
    end
    return nothing
end

const SPINNER_STYLES = (:dot, :circle, :toggle, :toggle2, :bar, :greek)

# Term's spinner styles side by side. `TermBackend` uses one column
# configuration for every bar, so this scene calls `Term.Progress` directly.
function scene_spinners(_backend)
    pbar = Term.Progress.ProgressBar(; columns=:spinner, title="Term's spinner styles")
    Term.Progress.start!(pbar)
    template = copy(pbar.columns)
    jobs = map(SPINNER_STYLES) do style
        # A new job shares `pbar.columns`, which starting a job with no total
        # mutates, so each job is added with a fresh copy.
        pbar.columns = copy(template)
        Term.Progress.addjob!(
            pbar;
            description=string(":", style),
            columns_kwargs=Dict(:SpinnerColumn => Dict(:spinnertype => style)),
        )
    end
    deadline = time() + 4.0
    while time() < deadline
        Term.Progress.render(pbar)
        sleep(0.08)
    end
    for job in jobs
        Term.Progress.removejob!(pbar, job)
    end
    Term.Progress.stop!(pbar)
    return nothing
end

# --------------------------------------------------------------- catalogue --

struct Scene
    name::String
    summary::String
    run::Function
    expect::Union{Type,Nothing}    # the exception type this scene is meant to raise, or nothing
    fixedbackend::Union{String,Nothing}    # the only backend this scene runs through, or nothing for any of them
end

const BACKEND_NAMES = ("plaintext", "term", "progresslogging")

const SCENES = [
    Scene(
        "binary",
        "One binary phase: no count at all, just a spinner from open to close.",
        scene_binary,
        nothing,
        nothing,
    ),
    Scene(
        "counting",
        "One counting phase: a rising count with no total.",
        scene_counting,
        nothing,
        nothing,
    ),
    Scene(
        "determinate",
        "One determinate phase: a bar filling towards a known total.",
        scene_determinate,
        nothing,
        nothing,
    ),
    Scene(
        "full-run",
        "Three chains at once, each moving through a binary, a counting, then a determinate phase in turn.",
        scene_fullrun,
        nothing,
        nothing,
    ),
    Scene(
        "finished",
        "A run of two chains that completes normally.",
        scene_finished,
        nothing,
        nothing,
    ),
    Scene(
        "failed",
        "A run that raises an ordinary exception partway through, leaving a phase open for the teardown to close.",
        scene_failed,
        ErrorException,
        nothing,
    ),
    Scene(
        "interrupted",
        "A run that raises InterruptException partway through, standing in for Ctrl-C, to show the terminal is left intact.",
        scene_interrupted,
        InterruptException,
        nothing,
    ),
    Scene(
        "spinners",
        "Term's spinner styles shown side by side: $(join(SPINNER_STYLES, ", ")).",
        scene_spinners,
        nothing,
        "term",
    ),
]

function find_scene(name::AbstractString)
    i = findfirst(s -> s.name == name, SCENES)
    i === nothing && throw(
        ArgumentError(
            "unknown scene \"$name\"; valid scenes are $(join((s.name for s in SCENES), ", "))",
        ),
    )
    return SCENES[i]
end

# The backend name a scene actually runs with: `scene`'s own fixed backend if
# it has one, otherwise `requested`, falling back to plain text.
function resolve_backend_name(scene::Scene, requested::Union{AbstractString,Nothing})
    if scene.fixedbackend !== nothing
        requested === nothing ||
            requested == scene.fixedbackend ||
            throw(
                ArgumentError(
                    "the \"$(scene.name)\" scene only runs through the $(scene.fixedbackend) backend, got \"$requested\"",
                ),
            )
        return scene.fixedbackend
    end
    name = requested === nothing ? "plaintext" : requested
    name in BACKEND_NAMES || throw(
        ArgumentError(
            "unknown backend \"$name\"; valid backends are $(join(BACKEND_NAMES, ", "))",
        ),
    )
    return name
end

# Build the backend named `name` and call `f` with it. The ProgressLogging
# backend only emits log records, so a `TerminalLogger` is installed for the
# duration of the call to display them.
function with_backend(f, name::AbstractString)
    if name == "plaintext"
        f(PlainTextBackend())
    elseif name == "term"
        f(TermBackend())
    elseif name == "progresslogging"
        with_logger(TerminalLogger()) do
            f(ProgressLoggingBackend())
        end
    else
        throw(
            ArgumentError(
                "unknown backend \"$name\"; valid backends are $(join(BACKEND_NAMES, ", "))",
            ),
        )
    end
    return nothing
end

function run_scene(scene::Scene, requested::Union{AbstractString,Nothing})
    backendname = resolve_backend_name(scene, requested)
    println()
    println("=== ", scene.name, " (", backendname, ") ===")
    println(scene.summary)
    println()
    try
        with_backend(scene.run, backendname)
        scene.expect === nothing || error(
            "scene \"$(scene.name)\" was meant to end by raising $(scene.expect), but it returned normally",
        )
    catch exception
        if scene.expect !== nothing && exception isa scene.expect
            println()
            println("(the run ended by raising: ", sprint(showerror, exception), ")")
            println(
                "(that is the point of the \"",
                scene.name,
                "\" scene. The gallery catches it so the scenes after this one still run, ",
                "and this line printing normally is the terminal left intact.)",
            )
        else
            rethrow()
        end
    end
    return nothing
end

# Run every scene that takes a backend through `requested` (plain text if
# `nothing`). The spinner scene only runs with `--scene spinners`.
function run_all(requested::Union{AbstractString,Nothing})
    for scene in SCENES
        scene.fixedbackend === nothing || continue
        run_scene(scene, requested)
    end
    println()
    println("Term's spinner styles are their own scene: --scene spinners")
    return nothing
end

# ---------------------------------------------------------------- command line --

mutable struct Options
    help::Bool
    list::Bool
    all::Bool
    scene::Union{String,Nothing}
    backend::Union{String,Nothing}
end
Options() = Options(false, false, false, nothing, nothing)

function parse_args(args)
    opts = Options()
    i = firstindex(args)
    while i <= lastindex(args)
        arg = args[i]
        if arg == "--help" || arg == "-h"
            opts.help = true
        elseif arg == "--list"
            opts.list = true
        elseif arg == "--all"
            opts.all = true
        elseif arg == "--scene"
            i == lastindex(args) && throw(
                ArgumentError("--scene needs a scene name; run with --list to see them"),
            )
            i += 1
            opts.scene = args[i]
        elseif arg == "--backend"
            i == lastindex(args) && throw(
                ArgumentError(
                    "--backend needs a backend name: $(join(BACKEND_NAMES, ", "))",
                ),
            )
            i += 1
            opts.backend = args[i]
        else
            throw(
                ArgumentError("unrecognised argument \"$arg\"; run with --help for usage"),
            )
        end
        i += 1
    end
    return opts
end

function print_listing()
    println("Scenes:")
    for scene in SCENES
        backends =
            scene.fixedbackend === nothing ? join(BACKEND_NAMES, ", ") : scene.fixedbackend
        println("  ", rpad(scene.name, 12), scene.summary)
        println("  ", " "^12, "(backend: ", backends, ")")
    end
    println()
    println("Backends: ", join(BACKEND_NAMES, ", "))
    return nothing
end

function print_usage()
    println("A runnable showcase of MCMCProgress's phase kinds, endings, and backends.")
    println()
    println("Usage:")
    println("  julia --project=examples examples/gallery.jl --list")
    println("  julia --project=examples examples/gallery.jl --scene NAME [--backend NAME]")
    println("  julia --project=examples examples/gallery.jl --all [--backend NAME]")
    println("  julia --project=examples examples/gallery.jl --help")
    println()
    println("Options:")
    println("  --scene NAME     run one scene; see the scene list below")
    println("  --backend NAME   plaintext, term, or progresslogging (default: plaintext)")
    println("  --all            run every scene that takes a backend, once each")
    println("  --list           print the scene and backend list below, then exit")
    println("  --help, -h       print this message and exit")
    println()
    print_listing()
    return nothing
end

function main(args=ARGS)
    opts = parse_args(args)
    if opts.help || isempty(args)
        print_usage()
        return nothing
    elseif opts.list
        print_listing()
        return nothing
    end
    opts.all &&
        opts.scene !== nothing &&
        throw(ArgumentError("pass either --scene or --all, not both"))
    if opts.all
        run_all(opts.backend)
    elseif opts.scene !== nothing
        run_scene(find_scene(opts.scene), opts.backend)
    else
        throw(
            ArgumentError("pass --scene NAME, --all, or --list; run with --help for usage"),
        )
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
