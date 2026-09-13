# Term writes control sequences straight to the process's real `stdout`
# whenever a job starts, stops, or a bar renders — `Term.Progress.ProgressJob`
# and `ProgressBar`'s own `start!`/`stop!`/`addjob!` are not parameterised by
# an `IO` argument the way `render` is. Wrapping every call into the
# extension in `quietly` redirects that real `stdout` to `devnull` for the
# duration of the call, so the suite prints nothing and a failing `@test`
# outside the wrapped call still reports normally.
quietly(f) = redirect_stdout(f, devnull)

@testset "the run's label becomes the progress bar's title" begin
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end
    @test handle.pbar.title == "Sampling mymodel"
    quietly() do
        teardown(handle, rs0)
    end
end

@testset "N is supplied for a determinate phase and withheld for counting and binary phases" begin
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end

    det = PhaseSnapshot(UInt(1), "Warmup", Determinate(500), 0, UInt64(0), nothing)
    counting = PhaseSnapshot(UInt(2), "Adapting", Counting(), 0, UInt64(0), nothing)
    binary = PhaseSnapshot(UInt(3), "Finding step size", Binary(), 0, UInt64(0), nothing)
    quietly() do
        phase_opened(handle, 1, det)
        phase_opened(handle, 1, counting)
        phase_opened(handle, 1, binary)
    end

    det_job, counting_job, binary_job =
        handle.jobs[UInt(1)], handle.jobs[UInt(2)], handle.jobs[UInt(3)]
    @test det_job.N == 500
    @test counting_job.N === nothing
    @test binary_job.N === nothing

    # A determinate phase draws a bar; counting and binary phases get Term's
    # own spinner instead, attached by `ProgressJob.start!` once a job's `N`
    # is `nothing`.
    @test any(c -> c isa Term.Progress.ProgressColumn, det_job.columns)
    @test !any(c -> c isa Term.Progress.SpinnerColumn, det_job.columns)
    @test any(c -> c isa Term.Progress.SpinnerColumn, counting_job.columns)
    @test any(c -> c isa Term.Progress.SpinnerColumn, binary_job.columns)

    quietly() do
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(1), "Warmup", Determinate(500), 500, UInt64(0), UInt64(1)),
        )
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(2), "Adapting", Counting(), 7, UInt64(0), UInt64(1)),
        )
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(3), "Finding step size", Binary(), 0, UInt64(0), UInt64(1)),
        )
        teardown(handle, rs0)
    end
end

@testset "the default column set omits elapsed time but keeps the remaining-time estimate" begin
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end
    det = PhaseSnapshot(UInt(1), "Warmup", Determinate(10), 0, UInt64(0), nothing)
    quietly() do
        phase_opened(handle, 1, det)
    end
    job = handle.jobs[UInt(1)]

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
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
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

@testset "one job per phase; two phases sharing a name get two distinct jobs" begin
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = quietly() do
        setup(MCMCProgress.TermBackend(), rs0)
    end

    p1 = PhaseSnapshot(UInt(1), "Adapting", Counting(), 0, UInt64(0), nothing)
    quietly() do
        phase_opened(handle, 1, p1)
    end
    job1 = handle.jobs[UInt(1)]
    quietly() do
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(1), "Adapting", Counting(), 5, UInt64(0), UInt64(1)),
        )
    end

    p2 = PhaseSnapshot(UInt(2), "Adapting", Counting(), 0, UInt64(0), nothing)  # a second bout of adaptation
    quietly() do
        phase_opened(handle, 1, p2)
    end
    job2 = handle.jobs[UInt(2)]

    @test job1 !== job2  # distinct jobs even though the phases share a name

    quietly() do
        phase_closed(
            handle,
            1,
            PhaseSnapshot(UInt(2), "Adapting", Counting(), 3, UInt64(0), UInt64(2)),
        )
        teardown(handle, rs0)
    end
end

@testset "a sampling phase's time-remaining clock is not distorted by a slow adaptation before it" begin
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
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
    job = handle.jobs[UInt(2)]

    # ADR-0004: Term times each job from its own `startime`, stamped by
    # `ProgressJob.start!` when the job is created, so a bar per phase resets
    # that clock at every phase boundary. The sampling job's clock starts now
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

@testset "interrupting a run leaves no live progress bar behind" begin
    rs0 = RunSnapshot(
        "Sampling mymodel",
        [
            ChainSnapshot(1, PhaseSnapshot[], nothing),
            ChainSnapshot(2, PhaseSnapshot[], nothing),
        ],
    )
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

    @test isempty(handle.pbar.jobs)
    @test handle.pbar.running == false
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
