# Term writes control sequences straight to the process's real `stdout`
# whenever a job starts, stops, or a bar renders — `Term.Progress.ProgressJob`
# and `ProgressBar`'s own `start!`/`stop!`/`addjob!` are not parameterised by
# an `IO` argument the way `render` is. Wrapping every call into the
# extension in `quietly` redirects that real `stdout` to `devnull` for the
# duration of the call, so the suite prints nothing and a failing `@test`
# outside the wrapped call still reports normally.
quietly(f) = redirect_stdout(f, devnull)

# `quietly`, but keeping what was written so a test can assert on what the
# terminal was told to draw.
function loudly(f)
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
    written = @async read(pipe, String)
    try
        redirect_stdout(f, pipe)
    finally
        close(pipe.in)
    end
    return fetch(written)
end

runsnapshot(nchains::Integer) = RunSnapshot(
    "Sampling mymodel",
    [ChainSnapshot(j, PhaseSnapshot[], nothing) for j in 1:nchains],
)

@testset "the run's label becomes the progress bar's title" begin
    rs0 = runsnapshot(1)
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end
    @test handle.pbar.title == "Sampling mymodel"
    quietly() do
        teardown(handle, rs0)
    end
end

@testset "one bar per chain, created before the run starts and kept for the whole run" begin
    rs0 = runsnapshot(3)
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end
    @test length(handle.pbar.jobs) == 3
    @test Set(keys(handle.jobs)) == Set(1:3)

    # Term scrolls the terminal for every job added to a running bar, so the
    # number of jobs must not change as chains move from phase to phase.
    quietly() do
        for j in 1:3
            phase_opened(
                handle,
                j,
                PhaseSnapshot(UInt(j), "Warmup", Determinate(500), 0, UInt64(0), nothing),
            )
        end
        for j in 1:3
            phase_closed(
                handle,
                j,
                PhaseSnapshot(
                    UInt(j),
                    "Warmup",
                    Determinate(500),
                    500,
                    UInt64(0),
                    UInt64(1),
                ),
            )
            phase_opened(
                handle,
                j,
                PhaseSnapshot(
                    UInt(10 + j),
                    "Sampling",
                    Determinate(100),
                    0,
                    UInt64(0),
                    nothing,
                ),
            )
        end
    end
    @test length(handle.pbar.jobs) == 3

    quietly() do
        teardown(handle, rs0)
    end
end

@testset "closing one chain's phase leaves every other chain's bar alone" begin
    rs0 = runsnapshot(4)
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end

    warmups = [
        PhaseSnapshot(UInt(j), "Warmup", Determinate(40), 0, UInt64(0), nothing) for
        j in 1:4
    ]
    quietly() do
        for j in 1:4
            phase_opened(handle, j, warmups[j])
        end
        # Chain 1 alone moves on to sampling, and later finishes it.
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(1), "Warmup", Determinate(40), 40, UInt64(0), UInt64(1)),
        )
        phase_opened(
            handle,
            1,
            PhaseSnapshot(UInt(11), "Sampling", Determinate(20), 0, UInt64(0), nothing),
        )
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(11), "Sampling", Determinate(20), 20, UInt64(0), UInt64(2)),
        )
    end

    # Chains 2 to 4 are still in warmup and must still say so: Term identifies a
    # job by an `id` it derives from how many jobs the bar holds, so a display
    # that added and removed a job per phase deleted another chain's bar here.
    for j in 2:4
        @test handle.jobs[j].description == "chain $j · Warmup"
        @test handle.jobs[j].N == 40
    end
    @test handle.jobs[1].description == "chain 1 · Sampling"
    @test length(handle.pbar.jobs) == 4

    quietly() do
        teardown(handle, rs0)
    end
end

@testset "a chain's bar takes the description, total and columns of the phase it is in" begin
    rs0 = runsnapshot(1)
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end

    det = PhaseSnapshot(UInt(1), "Warmup", Determinate(500), 0, UInt64(0), nothing)
    quietly() do
        phase_opened(handle, 1, det)
    end
    job = handle.jobs[1]
    @test job.description == "chain 1 · Warmup"
    @test job.N == 500
    # A determinate phase draws a bar; counting and binary phases get Term's
    # own spinner instead, attached by `ProgressJob.start!` once a job's `N`
    # is `nothing`.
    @test any(c -> c isa Term.Progress.ProgressColumn, job.columns)
    @test !any(c -> c isa Term.Progress.SpinnerColumn, job.columns)

    counting = PhaseSnapshot(UInt(2), "Adapting", Counting(), 0, UInt64(0), nothing)
    quietly() do
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(1), "Warmup", Determinate(500), 500, UInt64(0), UInt64(1)),
        )
        phase_opened(handle, 1, counting)
    end
    @test handle.jobs[1] === job  # the same bar, pointed at the next phase
    @test job.N === nothing
    @test job.i == 0
    @test any(c -> c isa Term.Progress.SpinnerColumn, job.columns)

    binary = PhaseSnapshot(UInt(3), "Finding step size", Binary(), 0, UInt64(0), nothing)
    quietly() do
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(2), "Adapting", Counting(), 7, UInt64(0), UInt64(2)),
        )
        phase_opened(handle, 1, binary)
    end
    @test job.N === nothing
    @test any(c -> c isa Term.Progress.SpinnerColumn, job.columns)

    # A determinate phase after a phase with no total gets its bar column back.
    quietly() do
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(3), "Finding step size", Binary(), 0, UInt64(0), UInt64(3)),
        )
        phase_opened(
            handle,
            1,
            PhaseSnapshot(UInt(4), "Sampling", Determinate(100), 0, UInt64(0), nothing),
        )
    end
    @test job.N == 100
    @test any(c -> c isa Term.Progress.ProgressColumn, job.columns)
    @test !any(c -> c isa Term.Progress.SpinnerColumn, job.columns)

    quietly() do
        teardown(handle, rs0)
    end
end

@testset "the default column set omits elapsed time but keeps the remaining-time estimate" begin
    rs0 = runsnapshot(1)
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end
    det = PhaseSnapshot(UInt(1), "Warmup", Determinate(10), 0, UInt64(0), nothing)
    quietly() do
        phase_opened(handle, 1, det)
    end
    job = handle.jobs[1]

    @test !any(c -> c isa Term.Progress.ElapsedColumn, job.columns)
    @test any(c -> c isa Term.Progress.ETAColumn, job.columns)

    quietly() do
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(1), "Warmup", Determinate(10), 10, UInt64(0), UInt64(1)),
        )
        teardown(handle, rs0)
    end
end

@testset "column configuration on the backend value reaches Term" begin
    mycols = DataType[Term.Progress.DescriptionColumn, Term.Progress.ProgressColumn]
    rs0 = runsnapshot(1)
    handle = quietly() do
        setup(MCMCProgress.TermBackend(mycols), rs0)
    end
    @test handle.template_columns == mycols

    kwargs_backend = MCMCProgress.TermBackend(;
        columns_kwargs=Dict{Symbol,Any}(:DescriptionColumn => Dict(:style => "red")),
    )
    handle2 = quietly() do
        setup(kwargs_backend, rs0)
    end
    @test handle2.pbar.columns_kwargs ==
          Dict{Symbol,Any}(:DescriptionColumn => Dict(:style => "red"))

    quietly() do
        teardown(handle, rs0)
        teardown(handle2, rs0)
    end
end

@testset "a sampling phase's time-remaining clock is not distorted by a slow adaptation before it" begin
    rs0 = runsnapshot(1)
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end

    warmup = PhaseSnapshot(UInt(1), "Warmup", Determinate(1), 0, UInt64(0), nothing)
    quietly() do
        phase_opened(handle, 1, warmup)
    end
    sleep(0.3)  # a slow adaptation phase
    quietly() do
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(1), "Warmup", Determinate(1), 1, UInt64(0), UInt64(1)),
        )
    end

    before_sampling_opened = Dates.now()
    sampling = PhaseSnapshot(UInt(2), "Sampling", Determinate(1000), 0, UInt64(0), nothing)
    quietly() do
        phase_opened(handle, 1, sampling)
    end
    job = handle.jobs[1]

    # ADR-0004: Term times a job from its own `startime`. Pointing a chain's bar
    # at a new phase re-stamps that field, so the sampling estimate starts now
    # rather than 0.3 s ago with the adaptation's.
    @test job.startime >= before_sampling_opened
    @test (Dates.now() - job.startime) < Dates.Millisecond(200)  # well under the 300 ms adaptation

    quietly() do
        phase_closed(
            handle,
            1,
            PhaseSnapshot(
                UInt(2),
                "Sampling",
                Determinate(1000),
                1000,
                UInt64(0),
                UInt64(1),
            ),
        )
        teardown(handle, rs0)
    end
end

@testset "tearing down draws where the run ended" begin
    rs0 = runsnapshot(1)
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end
    sampling = PhaseSnapshot(UInt(1), "Sampling", Determinate(50), 0, UInt64(0), nothing)
    closed = PhaseSnapshot(UInt(1), "Sampling", Determinate(50), 50, UInt64(0), UInt64(1))
    quietly() do
        phase_opened(handle, 1, sampling)
    end

    # The refresh task has stopped by the time a run is torn down, so this is
    # the only chance to draw the closing positions: without it the terminal
    # keeps a frame from up to a refresh period before the run ended.
    drawn = loudly() do
        phase_closed(handle, 1, closed)
        teardown(handle, RunSnapshot(rs0.label, [ChainSnapshot(1, [closed], finished)]))
    end
    @test occursin("50", drawn)
    @test occursin("100%", drawn)
end

@testset "interrupting a run stops the progress bar and leaves each chain where it stopped" begin
    rs0 = runsnapshot(2)
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end

    p1 = PhaseSnapshot(UInt(1), "Warmup", Determinate(100), 40, UInt64(0), nothing)
    p2 = PhaseSnapshot(UInt(2), "Finding step size", Binary(), 0, UInt64(0), nothing)
    quietly() do
        phase_opened(handle, 1, p1)
        phase_opened(handle, 2, p2)
    end
    @test length(handle.pbar.jobs) == 2

    # The core closes every phase a run left open before tearing the backend
    # down, however the run ends (`endrun!` in scope.jl) — simulating that
    # sequence here is what an interruption looks like from the backend side.
    p1_closed = PhaseSnapshot(UInt(1), "Warmup", Determinate(100), 40, UInt64(0), UInt64(1))
    p2_closed =
        PhaseSnapshot(UInt(2), "Finding step size", Binary(), 0, UInt64(0), UInt64(1))
    quietly() do
        phase_closed(handle, 1, p1_closed)
        phase_closed(handle, 2, p2_closed)
        teardown(
            handle,
            RunSnapshot(
                rs0.label,
                [
                    ChainSnapshot(1, [p1_closed], interrupted),
                    ChainSnapshot(2, [p2_closed], interrupted),
                ],
            ),
        )
    end

    @test handle.pbar.running == false
    @test handle.jobs[1].i == 40  # the position chain 1 had reached when it was cut short
    @test all(job -> job.finished, values(handle.jobs))
end

@testset "an interrupted run using the Term backend still ends and rethrows" begin
    caught = nothing
    quietly() do
        try
            MCMCProgress.displayrun(
                "Sampling mymodel",
                2,
                MCMCProgress.TermBackend(),
                MCMCProgress.REFRESH_PERIOD,
            ) do run
                openphase!(chain(run, 1), "Warmup", Determinate(100))
                throw(InterruptException())
            end
        catch exception
            caught = exception
        end
    end
    @test caught isa InterruptException
end

@testset "backend_package names the Term extension" begin
    @test MCMCProgress.backend_package(MCMCProgress.TermBackend()) == "Term"
end
