# ProgressLogging's own level sits between Debug and Info, so a plain
# `collect_test_logs` call (whose default `min_level` is Info) would miss
# every record this backend emits unless `min_level` is lowered to it.
capture_progress_logs(f) =
    Test.collect_test_logs(f; min_level=ProgressLogging.ProgressLevel)

@testset "ProgressLoggingBackend emits records at ProgressLogging's own level" begin
    logs, _ = capture_progress_logs() do
        progress(;
            label="Sampling mymodel",
            nchains=1,
            backend=MCMCProgress.ProgressLoggingBackend(),
        ) do run
            p = openphase!(chain(run, 1), "Warmup", Determinate(2))
            advance!(p, 1)
            advance!(p, 2)
            closephase!(p)
        end
    end
    @test !isempty(logs)
    @test all(r -> r.level == ProgressLogging.ProgressLevel, logs)
end

@testset "the backend installs no logger of its own" begin
    before = Logging.global_logger()
    progress(;
        label="Sampling mymodel",
        nchains=1,
        backend=MCMCProgress.ProgressLoggingBackend(),
    ) do run
        nothing
    end
    @test Logging.global_logger() === before
end

@testset "backend_package names the ProgressLogging extension" begin
    @test MCMCProgress.backend_package(MCMCProgress.ProgressLoggingBackend()) ==
          "ProgressLogging"
end

@testset "a record's name carries the chain index and the phase name" begin
    backend = MCMCProgress.ProgressLoggingBackend()
    rs0 = RunSnapshot(
        "Sampling mymodel",
        [
            ChainSnapshot(1, PhaseSnapshot[], nothing),
            ChainSnapshot(2, PhaseSnapshot[], nothing),
        ],
    )
    handle = setup(backend, rs0)
    p = PhaseSnapshot(UInt(1), "Warmup", Determinate(4), 0, UInt64(0), nothing)

    logs, _ = capture_progress_logs() do
        phase_opened(handle, 2, p)
    end
    @test occursin("2", string(logs[1].message))
    @test occursin("Warmup", string(logs[1].message))
end

@testset "a determinate phase reports a fraction; counting and binary report nothing" begin
    backend = MCMCProgress.ProgressLoggingBackend()
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)

    det_open = PhaseSnapshot(UInt(1), "Warmup", Determinate(4), 0, UInt64(0), nothing)
    det_mid = PhaseSnapshot(UInt(1), "Warmup", Determinate(4), 2, UInt64(0), nothing)
    logs, _ = capture_progress_logs() do
        phase_opened(handle, 1, det_open)
        refresh(handle, RunSnapshot(rs0.label, [ChainSnapshot(1, [det_mid], nothing)]))
    end
    @test logs[1].kwargs[:progress] == 0.0
    @test logs[2].kwargs[:progress] == 0.5

    count_open = PhaseSnapshot(UInt(2), "Adapting", Counting(), 0, UInt64(0), nothing)
    binary_open =
        PhaseSnapshot(UInt(3), "Finding step size", Binary(), 0, UInt64(0), nothing)
    logs2, _ = capture_progress_logs() do
        phase_opened(handle, 1, count_open)
        phase_opened(handle, 1, binary_open)
    end
    @test all(r -> r.kwargs[:progress] === nothing, logs2)
end

@testset "a closing phase reports \"done\"" begin
    backend = MCMCProgress.ProgressLoggingBackend()
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)
    p_open = PhaseSnapshot(UInt(1), "Warmup", Binary(), 0, UInt64(0), nothing)
    p_closed = PhaseSnapshot(UInt(1), "Warmup", Binary(), 0, UInt64(0), UInt64(1))

    logs, _ = capture_progress_logs() do
        phase_opened(handle, 1, p_open)
        phase_closed(handle, 1, p_closed)
    end
    @test logs[2].kwargs[:progress] == "done"
    @test logs[1].id == logs[2].id  # the close reports under the id the open minted
end

@testset "a fresh UUID per phase, distinct even when two phases share a name" begin
    backend = MCMCProgress.ProgressLoggingBackend()
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)
    p1 = PhaseSnapshot(UInt(10), "Warmup", Counting(), 0, UInt64(0), nothing)
    p2 = PhaseSnapshot(UInt(20), "Warmup", Counting(), 0, UInt64(0), nothing)

    logs, _ = capture_progress_logs() do
        phase_opened(handle, 1, p1)
        phase_opened(handle, 1, p2)
    end
    @test logs[1].id isa Base.UUID
    @test logs[2].id isa Base.UUID
    @test logs[1].id != logs[2].id
end

@testset "each phase produces exactly one done record, including phases teardown closes after an exception" begin
    caught = nothing
    logs, _ = capture_progress_logs() do
        try
            MCMCProgress.displayrun(
                "Sampling mymodel",
                2,
                MCMCProgress.ProgressLoggingBackend(),
                MCMCProgress.REFRESH_PERIOD,
            ) do run
                p1 = openphase!(chain(run, 1), "Warmup", Determinate(10))
                advance!(p1, 3)
                openphase!(chain(run, 2), "Warmup", Counting())  # left open when the error hits
                error("the sampler blew up")
            end
        catch exception
            caught = exception
        end
    end
    @test caught isa ErrorException

    ids = unique(r.id for r in logs)
    @test length(ids) == 2  # one phase per chain produced records
    for id in ids
        done_count = count(r -> r.id == id && r.kwargs[:progress] == "done", logs)
        @test done_count == 1
    end
end
