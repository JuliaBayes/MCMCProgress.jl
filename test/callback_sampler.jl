# A sampler that runs its own adaptation and sampling loops and reports an
# absolute step number through a callback, so its loops cannot be wrapped in a
# block owned by the caller.

"""
    PhaseReporter(chain, name, total=nothing)

Reports one chain's progress for a sampler that owns its loops. Holds the phase
open on `chain`, opening the first one, `name`, on construction. A `total` makes
that phase determinate; without one it counts.

`steps` holds every step the sampler reported, and `positions` the phase's
position immediately after each report.
"""
mutable struct PhaseReporter
    chain::MCMCProgress.Chain
    phase::MCMCProgress.Phase
    steps::Vector{Int}
    positions::Vector{Int}
end

PhaseReporter(c::MCMCProgress.Chain, name::AbstractString, total=nothing) =
    PhaseReporter(c, open_phase!(c, name, phase_kind(total)), Int[], Int[])

# `nothing` means the sampler knows no total.
phase_kind(total::Integer) = Determinate(total)
phase_kind(::Nothing) = Counting()

"""
    report!(reporter::PhaseReporter, step::Integer; meta...)

Record that the sampler has reached `step`, counted from the start of the
reporter's phase. `meta` is accepted and ignored.
"""
function report!(r::PhaseReporter, step::Integer; meta...)
    advance!(r.phase, step)
    push!(r.steps, Int(step))
    push!(r.positions, r.phase.position)
    return nothing
end

"""
    next_phase!(reporter::PhaseReporter, name, total=nothing) -> Phase

Close the reporter's phase, then open a new one called `name`.
"""
function next_phase!(r::PhaseReporter, name::AbstractString, total=nothing)
    close_phase!(r.phase)
    r.phase = open_phase!(r.chain, name, phase_kind(total))
    return r.phase
end

"""
    finish!(reporter::PhaseReporter) -> Phase

Close the reporter's phase after the sampler's last phase.
"""
finish!(r::PhaseReporter) = close_phase!(r.phase)

"""
    abandon!(reporter::PhaseReporter) -> Outcome

End the chain as `failed` partway through a phase, leaving the phase open for
the run to close.

Uses the non-exported `MCMCProgress.set_outcome!`: an exception from the run's
body would end *every* unfinished chain as `failed`, not only this one.
"""
abandon!(r::PhaseReporter) = MCMCProgress.set_outcome!(r.chain, failed)

"""
    SamplerPlan(; warmup, sampling, warmuptotal, samplingtotal, abandonat, failat)

What one chain's sampler does: the step numbers it reports while adapting
(`warmup`) and then while sampling (`sampling`), the totals it declares for
those two phases, and a sampling step number at which it either gives up on the
chain (`abandonat`) or throws (`failat`). A total left out makes its phase count
instead of declaring a length.

Listing the steps lets a test skip a step, repeat one, or stop short of the
declared total.
"""
struct SamplerPlan
    warmup::Vector{Int}
    sampling::Vector{Int}
    warmuptotal::Union{Int,Nothing}
    samplingtotal::Union{Int,Nothing}
    abandonat::Union{Int,Nothing}
    failat::Union{Int,Nothing}
end

SamplerPlan(;
    warmup,
    sampling,
    warmuptotal=nothing,
    samplingtotal=nothing,
    abandonat=nothing,
    failat=nothing,
) = SamplerPlan(
    collect(Int, warmup),
    collect(Int, sampling),
    warmuptotal,
    samplingtotal,
    abandonat,
    failat,
)

# Report warmup steps, move to sampling, report sampling steps, then finish,
# abandon or throw as `plan` says.
function foreign_sample!(reporter::PhaseReporter, plan::SamplerPlan)
    for step in plan.warmup
        report!(reporter, step; stepsize=0.05)
    end
    next_phase!(reporter, "Sampling", plan.samplingtotal)
    for step in plan.sampling
        step == plan.failat && error("the chain broke down at step $step")
        if step == plan.abandonat
            abandon!(reporter)
            return nothing
        end
        report!(reporter, step)
    end
    finish!(reporter)
    return nothing
end

# Run the sampler for each chain on its own task and return the reporters. Every
# report after a reporter is created comes from inside the sampler.
function drive_chains(run::MCMCProgress.Run, plans::AbstractVector{SamplerPlan})
    reporters = map(eachindex(plans)) do j
        PhaseReporter(chain(run, j), "Warmup", plans[j].warmuptotal)
    end
    @sync for j in eachindex(plans)
        Threads.@spawn foreign_sample!(reporters[j], plans[j])
    end
    return reporters
end

# The snapshot passed to the backend's teardown: every phase closed, every chain ended.
teardown_snapshot(backend::MCMCProgress.RecordingBackend) =
    last(call for call in backend.calls if call[1] === :teardown)[2]

# What the backend was told about chain `j`'s phases, in the order it was told.
function phase_calls(backend::MCMCProgress.RecordingBackend, j::Integer)
    return [
        (call[1], call[3].name) for call in backend.calls if
        (call[1] === :phase_opened || call[1] === :phase_closed) && call[2] == j
    ]
end

# A chain that adapts and then samples, reporting every step number of both
# phases.
plain_plan(; kwargs...) =
    SamplerPlan(; warmup=1:12, sampling=1:20, warmuptotal=12, samplingtotal=20, kwargs...)

@testset "a sampler that owns its loops drives a run through its reporter" begin
    nchains = 3
    plans = [plain_plan() for _ in 1:nchains]
    backend = MCMCProgress.RecordingBackend()

    reporters = progress(; label="Sampling mymodel", nchains, backend) do run
        drive_chains(run, plans)
    end

    final = teardown_snapshot(backend)
    @test [c.outcome for c in final.chains] == fill(finished, nchains)
    for cs in final.chains
        @test [p.name for p in cs.phases] == ["Warmup", "Sampling"]
        @test [p.position for p in cs.phases] == [12, 20]
        @test all(p -> p.closed isa UInt64, cs.phases)
    end

    # Every chain's phase transitions reach the backend in order.
    for j in 1:nchains
        @test phase_calls(backend, j) == [
            (:phase_opened, "Warmup"),
            (:phase_closed, "Warmup"),
            (:phase_opened, "Sampling"),
            (:phase_closed, "Sampling"),
        ]
    end

    for (r, plan) in zip(reporters, plans)
        @test r.steps == vcat(plan.warmup, plan.sampling)
        @test r.positions == r.steps
    end
end

@testset "positions follow the sampler when it skips, repeats, or stops short" begin
    skipping = SamplerPlan(;
        warmup=[1, 2, 5, 9, 12],
        sampling=[4, 8, 20],
        warmuptotal=12,
        samplingtotal=20,
    )
    repeating = SamplerPlan(;
        warmup=[1, 1, 2, 2, 12],
        sampling=[1, 1, 2, 20],
        warmuptotal=12,
        samplingtotal=20,
    )
    stoppingshort = SamplerPlan(;
        warmup=[1, 2, 3],
        sampling=[1, 2, 3, 4, 5],
        warmuptotal=12,
        samplingtotal=20,
    )
    plans = [skipping, repeating, stoppingshort]
    backend = MCMCProgress.RecordingBackend()

    reporters = progress(; label="Sampling mymodel", nchains=length(plans), backend) do run
        drive_chains(run, plans)
    end

    # Positions are absolute, so each phase ends on the last step reported.
    final = teardown_snapshot(backend)
    @test [p.position for p in final.chains[1].phases] == [12, 20]
    @test [p.position for p in final.chains[2].phases] == [12, 20]
    # A sampler that stops short leaves each phase short of its total.
    @test [p.position for p in final.chains[3].phases] == [3, 5]
    @test [c.outcome for c in final.chains] == fill(finished, length(plans))

    # Every report set the position to the reported step.
    for (r, plan) in zip(reporters, plans)
        @test r.steps == vcat(plan.warmup, plan.sampling)
        @test r.positions == r.steps
    end
end

@testset "a sampler that abandons a chain partway leaves that chain failed" begin
    plans = [plain_plan(), plain_plan(; abandonat=4), plain_plan()]
    backend = MCMCProgress.RecordingBackend()

    progress(; label="Sampling mymodel", nchains=length(plans), backend) do run
        drive_chains(run, plans)
    end

    final = teardown_snapshot(backend)
    # Only the abandoned chain fails.
    @test [c.outcome for c in final.chains] == [finished, failed, finished]

    abandoned = last(final.chains[2].phases)
    @test abandoned.name == "Sampling"
    @test abandoned.position == 3  # the last number reported before giving up
    # The run closed the abandoned phase and announced it before teardown.
    @test abandoned.closed isa UInt64
    @test abandoned.closed >= abandoned.opened
    names = [call[1] for call in backend.calls]
    @test findlast(==(:phase_closed), names) < findlast(==(:teardown), names)
    @test (:phase_closed, "Sampling") in phase_calls(backend, 2)
end

@testset "an exception out of one chain's sampler ends every chain as failed" begin
    plans = [plain_plan(), plain_plan(; failat=4), plain_plan()]
    backend = MCMCProgress.RecordingBackend()

    @test_throws "the chain broke down at step 4" progress(;
        label="Sampling mymodel",
        nchains=length(plans),
        backend,
    ) do run
        drive_chains(run, plans)
    end

    # An exception fails every unfinished chain; `abandon!` fails one chain alone.
    final = teardown_snapshot(backend)
    @test [c.outcome for c in final.chains] == fill(failed, length(plans))
    @test all(p.closed isa UInt64 for cs in final.chains for p in cs.phases)
end

@testset "reporting accidents a callback-driven sampler can make are rejected" begin
    @testset "a step number past the end of a determinate phase" begin
        c = MCMCProgress.Chain(1)
        reporter = PhaseReporter(c, "Warmup", 3)
        report!(reporter, 3)
        @test_throws "the phase \"Warmup\" runs for 3 iterations, so it cannot advance to 4" report!(
            reporter,
            4,
        )
        @test reporter.phase.position == 3  # the rejected report changed nothing
    end

    @testset "a step number past the end, reported from inside a run" begin
        # An off-by-one sampler; the run rethrows and ends the display as for any failure.
        plans = [SamplerPlan(; warmup=1:3, sampling=1:4, warmuptotal=3, samplingtotal=3)]
        backend = MCMCProgress.RecordingBackend()
        @test_throws "cannot advance to 4" progress(;
            label="Sampling mymodel",
            nchains=1,
            backend,
        ) do run
            drive_chains(run, plans)
        end

        final = teardown_snapshot(backend)
        @test [c.outcome for c in final.chains] == [failed]
        @test last(final.chains[1].phases).name == "Sampling"
        @test last(final.chains[1].phases).closed isa UInt64
    end

    @testset "a report into a phase the sampler has already left" begin
        backend = MCMCProgress.RecordingBackend()
        @test_throws "the phase \"Warmup\" is closed, so it cannot advance to 8" progress(;
            label="Sampling mymodel",
            nchains=1,
            backend,
        ) do run
            reporter = PhaseReporter(chain(run, 1), "Warmup", 12)
            report!(reporter, 7)
            leftbehind = reporter.phase
            next_phase!(reporter, "Sampling", 20)
            # Code still holding the previous phase reports into it.
            advance!(leftbehind, 8)
        end

        final = teardown_snapshot(backend)
        @test [c.outcome for c in final.chains] == [failed]
        @test [p.name for p in final.chains[1].phases] == ["Warmup", "Sampling"]
        @test final.chains[1].phases[1].position == 7
    end

    @testset "a phase opened before the one in progress is closed" begin
        backend = MCMCProgress.RecordingBackend()
        @test_throws "still has the phase \"Warmup\" open" progress(;
            label="Sampling mymodel",
            nchains=1,
            backend,
        ) do run
            reporter = PhaseReporter(chain(run, 1), "Warmup", 12)
            report!(reporter, 3)
            # Opening a phase without closing the current one throws.
            open_phase!(reporter.chain, "Sampling", Determinate(20))
        end

        final = teardown_snapshot(backend)
        @test [p.name for p in final.chains[1].phases] == ["Warmup"]
        @test [c.outcome for c in final.chains] == [failed]
    end
end
