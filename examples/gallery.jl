# A runnable showcase of MCMCProgress: one scene per phase kind, a scene that
# runs several chains through all three kinds in sequence, a scene for each of
# the three endings a run can have, and Term's spinner styles side by side.
# Every scene runs through whichever backend is asked for on the command line,
# so the three backends can be compared against each other.
#
# The sampler each scene drives is fake: it sleeps for a small, slightly
# randomised interval per step rather than doing any work, which holds every
# scene to a few seconds on any machine.
#
# Run `julia --project=examples examples/gallery.jl --help` for usage.

using MCMCProgress
using Term
using ProgressLogging
using TerminalLoggers: TerminalLogger
using Logging: with_logger

# ------------------------------------------------------------------ sampler --

const STEP_SECONDS = 0.03

# One step of fake sampling work: long enough to see, short enough that a
# hundred of them still take a couple of seconds.
fakestep(seconds::Real=STEP_SECONDS) = sleep(seconds * (0.7 + 0.6 * rand()))

# Run a determinate phase called `name` on chain `c` to completion, from
# position 0 up to `total`.
function rundeterminate!(c, name::AbstractString, total::Integer; step=STEP_SECONDS)
    p = openphase!(c, name, Determinate(total))
    for i in 1:total
        fakestep(step)
        advance!(p, i)
    end
    closephase!(p)
    return nothing
end

# Run a counting phase called `name` on chain `c` for `n` steps. `n` is how
# far this call happens to take the count, not a total the phase knows about.
function runcounting!(c, name::AbstractString, n::Integer; step=STEP_SECONDS)
    p = openphase!(c, name, Counting())
    for i in 1:n
        fakestep(step)
        advance!(p, i)
    end
    closephase!(p)
    return nothing
end

# Run a binary phase called `name` on chain `c` for about `seconds` before
# closing it. A binary phase has no position, so there is nothing to advance.
function runbinary!(c, name::AbstractString, seconds::Real; step=STEP_SECONDS)
    p = openphase!(c, name, Binary())
    for _ in 1:max(1, round(Int, seconds/step))
        fakestep(step)
    end
    closephase!(p)
    return nothing
end

# ------------------------------------------------------------------- scenes --

function scene_binary(backend)
    progress(; label="A binary phase", nchains=1, backend) do run
        runbinary!(chain(run, 1), "Connecting", 1.5)
    end
    return nothing
end

# The count runs past 200 because the plain-text backend writes a counting
# phase's line once every hundred positions; a phase that stops short of a
# hundred would show only its first line and its last.
function scene_counting(backend)
    progress(; label="A counting phase", nchains=1, backend) do run
        runcounting!(chain(run, 1), "Warmup", 250; step=0.012)
    end
    return nothing
end

function scene_determinate(backend)
    progress(; label="A determinate phase", nchains=1, backend) do run
        rundeterminate!(chain(run, 1), "Sampling", 60)
    end
    return nothing
end

# Several chains at once, each moving through a binary, a counting, then a
# determinate phase in turn: connecting, then an adaptive warmup of unknown
# length, then a fixed number of draws. This is the shape of a real run.
function scene_fullrun(backend)
    nchains = 3
    progress(; label="Sampling mymodel", nchains, backend) do run
        @sync for j in 1:nchains
            Threads.@spawn begin
                c = chain(run, j)
                runbinary!(c, "Connecting", 0.8)
                runcounting!(c, "Warmup", 25)
                rundeterminate!(c, "Sampling", 50)
            end
        end
    end
    return nothing
end

# Two chains, both run to completion: the run ends `finished`.
function scene_finished(backend)
    progress(; label="A run that finishes", nchains=2, backend) do run
        rundeterminate!(chain(run, 1), "Sampling", 30)
        rundeterminate!(chain(run, 2), "Sampling", 30)
    end
    return nothing
end

# Chain 1 finishes its phase; chain 2 is left mid-phase when an ordinary
# exception ends the run's body, so both chains end `failed` and the run's
# teardown is what closes chain 2's open phase.
function scene_failed(backend)
    progress(; label="A run that fails", nchains=2, backend) do run
        rundeterminate!(chain(run, 1), "Sampling", 30)
        p = openphase!(chain(run, 2), "Sampling", Determinate(30))
        for i in 1:10
            fakestep()
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
        rundeterminate!(chain(run, 1), "Sampling", 20)
        p = openphase!(chain(run, 2), "Sampling", Determinate(30))
        for i in 1:8
            fakestep()
            advance!(p, i)
        end
        throw(InterruptException())
    end
    return nothing
end

const SPINNER_STYLES = (:dot, :circle, :toggle, :toggle2, :bar, :greek)

# Every spinner style Term ships, running side by side. A run's `TermBackend`
# draws every bar from one column configuration, so several spinner styles at
# once cannot be shown through the backend interface; this is the one scene that
# talks to Term.Progress directly.
function scene_spinners(_backend)
    pbar = Term.Progress.ProgressBar(; columns=:spinner, title="Term's spinner styles")
    Term.Progress.start!(pbar)
    template = copy(pbar.columns)
    jobs = map(SPINNER_STYLES) do style
        # A freshly added job starts out holding the very array `pbar.columns`
        # points to, not a copy of it, and starting a job with no total
        # mutates that array in place. Resetting `pbar.columns` to a fresh
        # copy before every `addjob!` call keeps one job's columns from
        # leaking into the next.
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

function findscene(name::AbstractString)
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
function resolvebackendname(scene::Scene, requested::Union{AbstractString,Nothing})
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
# backend emits log records and draws nothing itself, so it shows up only once a
# logger that understands those records is installed; `TerminalLogger` from
# TerminalLoggers.jl is installed here for the duration of the call, and the
# logger that was active before is restored after it.
function withbackend(f, name::AbstractString)
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

function runscene(scene::Scene, requested::Union{AbstractString,Nothing})
    backendname = resolvebackendname(scene, requested)
    println()
    println("=== ", scene.name, " (", backendname, ") ===")
    println(scene.summary)
    println()
    try
        withbackend(scene.run, backendname)
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

# Every scene that takes a backend, run once each through `requested` (or
# plain text if that is `nothing`). Term's spinner styles are their own scene,
# reached with `--scene spinners`, since they have no plain-text or
# ProgressLogging rendering to compare against.
function runall(requested::Union{AbstractString,Nothing})
    for scene in SCENES
        scene.fixedbackend === nothing || continue
        runscene(scene, requested)
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

function parseargs(args)
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

function printlisting()
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

function printusage()
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
    printlisting()
    return nothing
end

function main(args=ARGS)
    opts = parseargs(args)
    if opts.help || isempty(args)
        printusage()
        return nothing
    elseif opts.list
        printlisting()
        return nothing
    end
    opts.all &&
        opts.scene !== nothing &&
        throw(ArgumentError("pass either --scene or --all, not both"))
    if opts.all
        runall(opts.backend)
    elseif opts.scene !== nothing
        runscene(findscene(opts.scene), opts.backend)
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
