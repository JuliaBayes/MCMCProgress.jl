# `ProgressLevel` is below Info, the default `min_level` of `collect_test_logs`.
capture_progress_logs(f) =
    Test.collect_test_logs(f; min_level=ProgressLogging.ProgressLevel)

struct RejectProgressOpen <: Logging.AbstractLogger
    id::Ref{Union{Nothing,Base.UUID}}
end
Logging.min_enabled_level(::RejectProgressOpen) = ProgressLogging.ProgressLevel
Logging.shouldlog(::RejectProgressOpen, args...) = true
Logging.catch_exceptions(::RejectProgressOpen) = false
function Logging.handle_message(
    logger::RejectProgressOpen, level, message, mod, group, id, file, line; kwargs...,
)
    logger.id[] = id
    error("progress logger rejected the opening record")
end

struct PhaseCallbackFailure
    callback::Symbol
    persistent::Bool
    seen::Threads.Atomic{Bool}
end
function fail_callback!(backend::PhaseCallbackFailure, callback)
    backend.callback === callback || return nothing
    first = !Threads.atomic_xchg!(backend.seen, true)
    (first || backend.persistent) && error("phase callback failed")
    return nothing
end
MCMCProgress.setup(b::PhaseCallbackFailure, ::RunSnapshot) = b
MCMCProgress.phase_opened(b::PhaseCallbackFailure, ::Integer, ::PhaseSnapshot) =
    fail_callback!(b, :opened)
MCMCProgress.phase_closed(b::PhaseCallbackFailure, ::Integer, ::PhaseSnapshot) =
    fail_callback!(b, :closed)
MCMCProgress.refresh(::PhaseCallbackFailure, ::RunSnapshot) = nothing
MCMCProgress.teardown(::PhaseCallbackFailure, ::RunSnapshot) = nothing

@testset "ProgressLoggingBackend emits records at ProgressLogging's own level" begin
    logs, _ = capture_progress_logs() do
        progress(;
            label="Sampling mymodel",
            nchains=1,
            backend=MCMCProgress.ProgressLoggingBackend(),
        ) do run
            p = open_phase!(chain_at(run, 1), "Warmup", Determinate(2))
            advance!(p, 1)
            advance!(p, 2)
            close_phase!(p)
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

@testset "a record's name carries the chain index, total and phase name" begin
    backend = MCMCProgress.ProgressLoggingBackend()
    rs0 = RunSnapshot(
        "Sampling mymodel",
        (
            ChainSnapshot(1, (), nothing),
            ChainSnapshot(2, (), nothing),
        ),
    )
    handle = setup(backend, rs0)
    p = PhaseSnapshot(UInt(1), "Warmup", Determinate(4), 0, UInt64(0), nothing)

    logs, _ = capture_progress_logs() do
        phase_opened(handle, 2, p)
    end
    @test logs[1].message == "chain 2/2: Warmup"
end

@testset "refresh throttles determinate updates and skips indeterminate updates" begin
    backend = MCMCProgress.ProgressLoggingBackend()
    rs0 = RunSnapshot("Sampling mymodel", (ChainSnapshot(1, (), nothing),))
    handle = setup(backend, rs0)
    snapshot(p) = RunSnapshot(rs0.label, (ChainSnapshot(1, (p,), nothing),))
    determinate(position) =
        PhaseSnapshot(UInt(1), "Warmup", Determinate(1000), position, UInt64(0), nothing)

    logs, _ = capture_progress_logs() do
        phase_opened(handle, 1, determinate(0))
        for position in (0, 1, 5, 5, 10, 15, 500, 999, 1000, 999)
            refresh(handle, snapshot(determinate(position)))
        end
    end
    @test [log.kwargs[:progress] for log in logs] ==
          [0.0, 0.005, 0.01, 0.015, 0.5, 0.999, 1.0, 0.999]

    count_open = PhaseSnapshot(UInt(2), "Adapting", Counting(), 0, UInt64(0), nothing)
    binary_open =
        PhaseSnapshot(UInt(3), "Finding step size", Binary(), 0, UInt64(0), nothing)
    logs2, _ = capture_progress_logs() do
        phase_opened(handle, 1, count_open)
        refresh(handle, snapshot(count_open))
        phase_opened(handle, 1, binary_open)
        refresh(handle, snapshot(binary_open))
    end
    @test [log.kwargs[:progress] for log in logs2] == [nothing, nothing]
end

@testset "retrying a rejected open preserves the phase ID through close" begin
    backend = MCMCProgress.ProgressLoggingBackend()
    rs0 = RunSnapshot("Sampling mymodel", (ChainSnapshot(1, (), nothing),))
    handle = setup(backend, rs0)
    p_open = PhaseSnapshot(UInt(1), "Warmup", Binary(), 0, UInt64(0), nothing)
    p_closed = PhaseSnapshot(UInt(1), "Warmup", Binary(), 0, UInt64(0), UInt64(1))
    logger = RejectProgressOpen(Ref{Union{Nothing,Base.UUID}}(nothing))

    Logging.with_logger(logger) do
        @test_throws ErrorException phase_opened(handle, 1, p_open)
    end
    logs, _ = capture_progress_logs() do
        phase_opened(handle, 1, p_open)
        phase_closed(handle, 1, p_closed)
    end
    @test [(log.id, log.kwargs[:progress]) for log in logs] ==
          [(logger.id[], nothing), (logger.id[], "done")]
end

@testset "a fresh UUID per phase, distinct even when two phases share a name" begin
    backend = MCMCProgress.ProgressLoggingBackend()
    rs0 = RunSnapshot("Sampling mymodel", (ChainSnapshot(1, (), nothing),))
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
            MCMCProgress.display_run(
                "Sampling mymodel",
                2,
                MCMCProgress.ProgressLoggingBackend(),
                MCMCProgress.REFRESH_PERIOD,
            ) do run
                p1 = open_phase!(chain_at(run, 1), "Warmup", Determinate(10))
                advance!(p1, 3)
                open_phase!(chain_at(run, 2), "Warmup", Counting())  # left open when the error hits
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

@testset "sibling callback failures leave logging records balanced" begin
    for (callback, persistent) in ((:opened, false), (:closed, false), (:opened, true))
        @testset "$callback, persistent=$persistent" begin
            failing = PhaseCallbackFailure(callback, persistent, Threads.Atomic{Bool}(false))
            observer = MCMCProgress.RecordingBackend()
            caught = nothing
            logs, _ = capture_progress_logs() do
                try
                    progress(; label="test", nchains=1,
                             backend=(MCMCProgress.ProgressLoggingBackend(), failing, observer)) do run
                        p = open_phase!(chain_at(run, 1), "phase", Binary())
                        close_phase!(p)
                        timedwait(() -> failing.seen[], 10.0) === :ok ||
                            error("callback timed out")
                    end
                catch err
                    caught = err
                end
            end
            records = filter(r -> haskey(r.kwargs, :progress), logs)
            @test caught isa TaskFailedException
            @test length(unique(r.id for r in records)) == 1
            @test count(r -> r.kwargs[:progress] == "done", records) == 1
            if !persistent
                @test any(call -> call[1] === :phase_closed, observer.calls)
            end
        end
    end
end
