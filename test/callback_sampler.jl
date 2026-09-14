# A sampler that owns its own loops, and the reporter it reports through. They
# stand for foreign sampling code of the shape DynamicHMC has: the sampler drives
# adaptation and sampling itself and calls back with an absolute step number from
# inside those loops, so none of it can be wrapped in a block belonging to the
# caller.

"""
    PhaseReporter(chain, name, total=nothing)

Reports one chain's progress on behalf of a sampler that owns the loop. The
reporter holds the phase currently open on `chain`, opening the first one, called
`name`, as the reporter is created. A `total` makes that phase determinate;
without one it counts.

A sampler is handed a reporter and sees nothing else of a run: [`report!`](@ref)
records how far it has got, [`nextphase!`](@ref) moves it on to the phase that
follows, and [`finish!`](@ref) or [`abandon!`](@ref) ends the last one.

`steps` holds every step number the sampler has passed, and `positions` the
position the phase held immediately after each of those reports. Together they
say what the sampler asked for and what the phase made of it.
"""
mutable struct PhaseReporter
    chain::MCMCProgress.Chain
    phase::MCMCProgress.Phase
    steps::Vector{Int}
    positions::Vector{Int}
end

PhaseReporter(c::MCMCProgress.Chain, name::AbstractString, total=nothing) =
    PhaseReporter(c, openphase!(c, name, phasekind(total)), Int[], Int[])

# A sampler passes a plain total, or nothing where it knows none; the reporter
# turns that into a kind of phase.
phasekind(total::Integer) = Determinate(total)
phasekind(::Nothing) = Counting()

"""
    report!(reporter::PhaseReporter, step::Integer; meta...)

Record that the sampler has reached `step`, counted from the start of the phase
the reporter holds. `meta` is whatever else the sampler cares to pass and is
discarded: a phase records a position and nothing besides.
"""
function report!(r::PhaseReporter, step::Integer; meta...)
    advance!(r.phase, step)
    push!(r.steps, Int(step))
    push!(r.positions, r.phase.position)
    return nothing
end

"""
    nextphase!(reporter::PhaseReporter, name, total=nothing) -> Phase

Move the reporter on from the phase it holds to a new one called `name`. The
phase it holds is closed before the new one opens, which is the order a chain
requires.
"""
function nextphase!(r::PhaseReporter, name::AbstractString, total=nothing)
    closephase!(r.phase)
    r.phase = openphase!(r.chain, name, phasekind(total))
    return r.phase
end

"""
    finish!(reporter::PhaseReporter) -> Phase

Close the phase the reporter holds, the sampler having run every phase it has.
"""
finish!(r::PhaseReporter) = closephase!(r.phase)

"""
    abandon!(reporter::PhaseReporter) -> Outcome

Record that the sampler has given up on this chain partway through a phase: the
chain ends as `failed`, and the phase it was in stays open for the run to close
as it finishes off the display.

A chain's outcome is not part of the exported reporting interface, so this
reaches for `MCMCProgress.setoutcome!`. A sampler that abandons one chain and
carries on with the others has no other way to say so: an exception leaving the
run's body ends *every* chain that has not ended already, which loses the
distinction between the chain that broke down and the chains that were merely
cut short.
"""
abandon!(r::PhaseReporter) = MCMCProgress.setoutcome!(r.chain, failed)

"""
    SamplerPlan(; warmup, sampling, warmuptotal, samplingtotal, abandonat, failat)

What one chain's sampler does: the step numbers it reports while adapting
(`warmup`) and then while sampling (`sampling`), the totals it declares for
those two phases, and a sampling step number at which it either gives up on the
chain (`abandonat`) or throws (`failat`). A total left out makes its phase count
instead of declaring a length.

The step numbers are listed rather than counted out, which is what lets a test
have the sampler skip one, repeat one, or stop short of the total it declared.
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

# Adapt, announce the move into sampling, sample, end. Every position comes from
# inside a loop this function owns, and the phase the reports land in changes
# between those loops.
function foreignsample!(reporter::PhaseReporter, plan::SamplerPlan)
    for step in plan.warmup
        report!(reporter, step; stepsize=0.05)
    end
    nextphase!(reporter, "Sampling", plan.samplingtotal)
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

# Hand every chain of `run` to the sampler, each on a task of its own, and give
# back the reporters so a test can read what the sampler reported. The run's body
# reports nothing itself: a chain's first phase opens as its reporter is created,
# and every report after that comes from inside the sampler.
function drivechains(run::MCMCProgress.Run, plans::AbstractVector{SamplerPlan})
    reporters = map(eachindex(plans)) do j
        PhaseReporter(chain(run, j), "Warmup", plans[j].warmuptotal)
    end
    @sync for j in eachindex(plans)
        Threads.@spawn foreignsample!(reporters[j], plans[j])
    end
    return reporters
end

# The snapshot a run finished on: the one handed to the backend's teardown, by
# which point every phase has been closed and every chain has ended.
teardownsnapshot(backend::MCMCProgress.RecordingBackend) =
    last(call for call in backend.calls if call[1] === :teardown)[2]

# What the backend was told about chain `j`'s phases, in the order it was told.
function phasecalls(backend::MCMCProgress.RecordingBackend, j::Integer)
    return [
        (call[1], call[3].name) for call in backend.calls if
        (call[1] === :phase_opened || call[1] === :phase_closed) && call[2] == j
    ]
end

# A chain that adapts and then samples, reporting every step number of both
# phases.
plainplan(; kwargs...) =
    SamplerPlan(; warmup=1:12, sampling=1:20, warmuptotal=12, samplingtotal=20, kwargs...)

@testset "a sampler that owns its loops drives a run through its reporter" begin
    nchains = 3
    plans = [plainplan() for _ in 1:nchains]
    backend = MCMCProgress.RecordingBackend()

    reporters = progress(; label="Sampling mymodel", nchains, backend) do run
        drivechains(run, plans)
    end

    final = teardownsnapshot(backend)
    @test [c.outcome for c in final.chains] == fill(finished, nchains)
    for cs in final.chains
        @test [p.name for p in cs.phases] == ["Warmup", "Sampling"]
        @test [p.position for p in cs.phases] == [12, 20]
        @test all(p -> p.closed isa UInt64, cs.phases)
    end

    # Both phase transitions of every chain reach the backend, in the order the
    # sampler made them, against the chain they belong to.
    for j in 1:nchains
        @test phasecalls(backend, j) == [
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
        drivechains(run, plans)
    end

    # A position is absolute, so every phase ends on the last number its sampler
    # reported — whether the sampler passed over numbers on the way there or
    # gave the same one twice.
    final = teardownsnapshot(backend)
    @test [p.position for p in final.chains[1].phases] == [12, 20]
    @test [p.position for p in final.chains[2].phases] == [12, 20]
    # A sampler that stops short leaves each phase where it got to, not at the
    # total the phase declared.
    @test [p.position for p in final.chains[3].phases] == [3, 5]
    @test [c.outcome for c in final.chains] == fill(finished, length(plans))

    # Every single report, in flight, put the phase on the number reported: a
    # repeat left it where it was rather than adding to it, and a skip carried it
    # straight to the number it named.
    for (r, plan) in zip(reporters, plans)
        @test r.steps == vcat(plan.warmup, plan.sampling)
        @test r.positions == r.steps
    end
end

@testset "a sampler that abandons a chain partway leaves that chain failed" begin
    plans = [plainplan(), plainplan(; abandonat=4), plainplan()]
    backend = MCMCProgress.RecordingBackend()

    progress(; label="Sampling mymodel", nchains=length(plans), backend) do run
        drivechains(run, plans)
    end

    final = teardownsnapshot(backend)
    # The chain the sampler gave up on fails on its own, while the chains it saw
    # through finish.
    @test [c.outcome for c in final.chains] == [finished, failed, finished]

    abandoned = last(final.chains[2].phases)
    @test abandoned.name == "Sampling"
    @test abandoned.position == 3  # the last number reported before giving up
    # The sampler never closed this phase; the run did, as it finished off the
    # display, and told the backend so before tearing it down.
    @test abandoned.closed isa UInt64
    @test abandoned.closed >= abandoned.opened
    names = [call[1] for call in backend.calls]
    @test findlast(==(:phase_closed), names) < findlast(==(:teardown), names)
    @test (:phase_closed, "Sampling") in phasecalls(backend, 2)
end

@testset "an exception out of one chain's sampler ends every chain as failed" begin
    plans = [plainplan(), plainplan(; failat=4), plainplan()]
    backend = MCMCProgress.RecordingBackend()

    @test_throws "the chain broke down at step 4" progress(;
        label="Sampling mymodel",
        nchains=length(plans),
        backend,
    ) do run
        drivechains(run, plans)
    end

    # An outcome taken from how the body ended is the same for every chain that
    # has not ended already, so the chain that broke down cannot be told apart
    # from the chains that were merely cut short. A sampler that wants that
    # distinction records the outcome itself, as `abandon!` does.
    final = teardownsnapshot(backend)
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
        # A sampler one out in its own counting reports the step after the last
        # one its phase declared. The run passes that on to the caller and
        # finishes the display off as it would for any other failure.
        plans = [SamplerPlan(; warmup=1:3, sampling=1:4, warmuptotal=3, samplingtotal=3)]
        backend = MCMCProgress.RecordingBackend()
        @test_throws "cannot advance to 4" progress(;
            label="Sampling mymodel",
            nchains=1,
            backend,
        ) do run
            drivechains(run, plans)
        end

        final = teardownsnapshot(backend)
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
            nextphase!(reporter, "Sampling", 20)
            # Foreign code that kept hold of the phase from before the
            # transition reports into it once more.
            advance!(leftbehind, 8)
        end

        final = teardownsnapshot(backend)
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
            # Closing before opening is what `nextphase!` does, and skipping the
            # close is rejected rather than leaving two phases open at once.
            openphase!(reporter.chain, "Sampling", Determinate(20))
        end

        final = teardownsnapshot(backend)
        @test [p.name for p in final.chains[1].phases] == ["Warmup"]
        @test [c.outcome for c in final.chains] == [failed]
    end
end
