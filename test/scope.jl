# Test backends that record calls instead of drawing, and a shorter refresh period.

"""
    ClockBackend(; long=0, pause=0.0)

Records the start time of each refresh in `times`, and makes refresh number
`long` sleep for `pause` seconds after recording its time. `times` is guarded by
`lock`, so the body can read it during the run.
"""
mutable struct ClockBackend
    times::Vector{UInt64}
    long::Int
    pause::Float64
    lock::ReentrantLock
end

ClockBackend(; long::Integer=0, pause::Real=0.0) =
    ClockBackend(UInt64[], Int(long), Float64(pause), ReentrantLock())

MCMCProgress.setup(backend::ClockBackend, ::RunSnapshot) = backend

function MCMCProgress.refresh(backend::ClockBackend, ::RunSnapshot)
    n = lock(backend.lock) do
        push!(backend.times, time_ns())
        length(backend.times)
    end
    n == backend.long && sleep(backend.pause)
    return nothing
end

MCMCProgress.teardown(::ClockBackend, ::RunSnapshot) = nothing

refresh_count(backend::ClockBackend) = lock(() -> length(backend.times), backend.lock)

refresh_times(backend::ClockBackend) = lock(() -> copy(backend.times), backend.lock)

"""
    FailingBackend(failing::Symbol)

Records the name of every call in `calls`, and throws from the call named
`failing`: one of `:refresh`, `:phase_closed` or `:teardown`.
"""
mutable struct FailingBackend
    calls::Vector{Symbol}
    failing::Symbol
end

FailingBackend(failing::Symbol) = FailingBackend(Symbol[], failing)

function MCMCProgress.setup(backend::FailingBackend, ::RunSnapshot)
    push!(backend.calls, :setup)
    return backend
end

function MCMCProgress.refresh(backend::FailingBackend, ::RunSnapshot)
    push!(backend.calls, :refresh)
    backend.failing === :refresh && error("this backend cannot refresh")
    return nothing
end

function MCMCProgress.phase_closed(backend::FailingBackend, ::Integer, ::PhaseSnapshot)
    push!(backend.calls, :phase_closed)
    backend.failing === :phase_closed && error("this backend cannot close a phase")
    return nothing
end

function MCMCProgress.teardown(backend::FailingBackend, ::RunSnapshot)
    push!(backend.calls, :teardown)
    backend.failing === :teardown && error("this backend cannot tear down")
    return nothing
end

# 20 ms, so a body lasting 0.1 s sees several refreshes.
const TEST_PERIOD = UInt64(20_000_000)

quick_run(f, backend; nchains::Integer=1, period::UInt64=TEST_PERIOD) =
    MCMCProgress.display_run(f, "Sampling mymodel", nchains, backend, period)

call_names(backend::MCMCProgress.RecordingBackend) = [call[1] for call in backend.calls]

final_snapshot(backend::MCMCProgress.RecordingBackend) = last(backend.calls)[2]

# The middle value of `xs`, so one stray reading does not decide the result.
middling(xs) = sort(xs)[(length(xs)+1)÷2]

@testset "progress drives a backend from setup to teardown" begin
    backend = MCMCProgress.RecordingBackend()
    result = progress(; label="Sampling mymodel", nchains=2, backend=backend) do run
        c = chain_at(run, 1)
        p = open_phase!(c, "Warmup", Determinate(10))
        advance!(p, 10)
        close_phase!(p)
        :sampled
    end

    @test result === :sampled  # progress hands back whatever the body returns

    names = call_names(backend)
    @test first(names) === :setup
    @test last(names) === :teardown
    @test :phase_opened in names
    @test :phase_closed in names

    final = final_snapshot(backend)
    @test [c.outcome for c in final.chains] == [finished, finished]
    @test final.chains[1].phases[1].position == 10
end

@testset "progress uses the process-wide default backend when given none" begin
    saved_default = MCMCProgress._DEFAULT_BACKEND[]
    try
        backend = MCMCProgress.RecordingBackend()
        set_backend!(backend)
        progress(; label="Sampling mymodel", nchains=1) do run
            nothing
        end
        @test first(call_names(backend)) === :setup
        @test last(call_names(backend)) === :teardown
    finally
        MCMCProgress._DEFAULT_BACKEND[] = saved_default
    end
end

@testset "phases are announced to the backend in the order a chain opens them" begin
    backend = MCMCProgress.RecordingBackend()
    quick_run(backend) do run
        c = chain_at(run, 1)
        step = open_phase!(c, "Finding step size", Binary())
        close_phase!(step)
        warmup = open_phase!(c, "Warmup", Determinate(4))
        for i in 1:4
            advance!(warmup, i)
            sleep(TEST_PERIOD / 1e9)
        end
        close_phase!(warmup)
    end

    announcements = [
        call for
        call in backend.calls if call[1] === :phase_opened || call[1] === :phase_closed
    ]
    # A phase that opens and closes between refreshes is still announced twice, in order.
    @test [(call[1], call[3].name) for call in announcements] == [
        (:phase_opened, "Finding step size"),
        (:phase_closed, "Finding step size"),
        (:phase_opened, "Warmup"),
        (:phase_closed, "Warmup"),
    ]
    @test all(call[2] == 1 for call in announcements)  # the chain they belong to
end

@testset "a phase left open by the body is closed by the teardown" begin
    backend = MCMCProgress.RecordingBackend()
    quick_run(backend) do run
        open_phase!(chain_at(run, 1), "Warmup", Determinate(100))
        sleep(3 * TEST_PERIOD / 1e9)
        nothing
    end

    names = call_names(backend)
    @test last(names) === :teardown
    # The phase is announced as closed before the backend is torn down.
    @test findlast(==(:phase_closed), names) < findlast(==(:teardown), names)

    closing = last(call for call in backend.calls if call[1] === :phase_closed)
    @test closing[3].name == "Warmup"
    @test closing[3].closed isa UInt64

    phase = final_snapshot(backend).chains[1].phases[1]
    @test phase.closed isa UInt64
    @test phase.closed >= phase.opened
end

@testset "an exception from the body reaches the caller unchanged" begin
    backend = MCMCProgress.RecordingBackend()
    blewup = ErrorException("the sampler blew up")

    caught = nothing
    try
        quick_run(backend; nchains=2) do run
            open_phase!(chain_at(run, 1), "Warmup", Determinate(100))
            throw(blewup)
        end
    catch exception
        caught = exception
    end

    @test caught === blewup  # the same object, not a copy and not a wrapper

    # The backend is still torn down.
    @test last(call_names(backend)) === :teardown
    final = final_snapshot(backend)
    @test [c.outcome for c in final.chains] == [failed, failed]
    @test final.chains[1].phases[1].closed isa UInt64
end

@testset "an InterruptException ends the chains as interrupted" begin
    backend = MCMCProgress.RecordingBackend()
    @test_throws InterruptException quick_run(backend; nchains=3) do run
        open_phase!(chain_at(run, 2), "Warmup", Determinate(100))
        throw(InterruptException())
    end

    @test last(call_names(backend)) === :teardown
    final = final_snapshot(backend)
    @test [c.outcome for c in final.chains] == [interrupted, interrupted, interrupted]
    @test final.chains[2].phases[1].closed isa UInt64
end

@testset "a chain that recorded its own outcome keeps it" begin
    backend = MCMCProgress.RecordingBackend()
    caught = nothing
    try
        quick_run(backend; nchains=2) do run
            MCMCProgress.set_outcome!(chain_at(run, 1), finished)
            error("the sampler blew up")
        end
    catch exception
        caught = exception
    end

    @test caught isa ErrorException
    @test [c.outcome for c in final_snapshot(backend).chains] == [finished, failed]
end

@testset "the refresh task is stopped before progress returns, however it ends" begin
    bodies = [
        "returns" => (run -> (sleep(0.1); :done)),
        "throws" => (run -> (sleep(0.1); error("the sampler blew up"))),
        "is interrupted" => (run -> (sleep(0.1); throw(InterruptException()))),
    ]

    for (what, body) in bodies
        @testset "a body that $what" begin
            backend = MCMCProgress.RecordingBackend()
            try
                quick_run(body, backend)
            catch
                # This testset asserts what the backend is told, and when.
            end

            names = call_names(backend)
            # The assertions below need at least one refresh to have run.
            @test count(==(:refresh), names) >= 1
            @test last(names) === :teardown  # nothing is drawn after the teardown

            settled = length(backend.calls)
            sleep(5 * TEST_PERIOD / 1e9)  # generous: five refreshes would be due
            @test length(backend.calls) == settled  # no refresh arrives late
        end
    end
end

@testset "the backend is torn down even when an earlier teardown step throws" begin
    @testset "a backend that cannot close a phase" begin
        backend = FailingBackend(:phase_closed)
        @test_throws "this backend cannot close a phase" quick_run(backend) do run
            open_phase!(chain_at(run, 1), "Warmup", Determinate(100))
            nothing
        end
        @test :teardown in backend.calls
    end

    @testset "a backend that cannot refresh" begin
        backend = FailingBackend(:refresh)
        # The refresh task's exception is rethrown when the run stops it.
        @test_throws "this backend cannot refresh" quick_run(backend) do run
            sleep(0.1)
            nothing
        end
        @test :teardown in backend.calls
    end

    @testset "a backend that cannot tear down" begin
        backend = FailingBackend(:teardown)
        @test_throws "this backend cannot tear down" quick_run(backend) do run
            nothing
        end
        @test :teardown in backend.calls
    end
end

@testset "a failing teardown does not hide the exception from the body" begin
    backend = FailingBackend(:teardown)
    blewup = ErrorException("the sampler blew up")

    caught = nothing
    # The teardown's own failure is logged, so that neither exception is lost.
    @test_logs (:error,) match_mode = :any begin
        try
            quick_run(backend) do run
                throw(blewup)
            end
        catch exception
            caught = exception
        end
    end

    @test caught === blewup
    @test :teardown in backend.calls
end

@testset "the refresh task refreshes while the body runs" begin
    backend = ClockBackend()
    quick_run(backend) do run
        # A refresh task that never runs times out here instead of hanging.
        @test timedwait(() -> refresh_count(backend) >= 3, 10.0) === :ok
        nothing
    end
end

@testset "the refresh task is spawned on the pool the session has threads for" begin
    run = MCMCProgress.Run("Sampling mymodel", 1)
    backend = MCMCProgress.RecordingBackend()
    stop = Threads.Atomic{Bool}(true)  # already stopped, so the loop draws nothing
    task = MCMCProgress.spawn_refresh(
        run,
        backend,
        MCMCProgress.Announced(1),
        TEST_PERIOD,
        stop,
    )
    wait(task)

    # The interactive pool when the session has one.
    expected = Threads.threadpoolsize(:interactive) > 0 ? :interactive : :default
    @test Threads.threadpool(task) === expected
    @test isempty(backend.calls)
end

@testset "the refresh clock stays on its grid when a refresh runs long" begin
    period = UInt64(100)
    deadline = UInt64(1000)

    # A refresh done before its deadline: the next is a whole period later.
    @test MCMCProgress.next_deadline(deadline, period, deadline - UInt64(5)) ==
          deadline + period
    @test MCMCProgress.next_deadline(deadline, period, deadline + UInt64(50)) ==
          deadline + period

    # A refresh still running at the next deadline: that deadline is skipped.
    @test MCMCProgress.next_deadline(deadline, period, deadline + period) ==
          deadline + 2 * period
    @test MCMCProgress.next_deadline(deadline, period, deadline + 3 * period + UInt64(1)) ==
          deadline + 4 * period

    # For any overrun, the next deadline is the first grid point after `now`.
    function on_grid((p, d, now))
        next = MCMCProgress.next_deadline(d, p, now)
        return next > now && next <= now + p && (next - d) % p == 0
    end

    draws = map(1:200) do _
        p = UInt64(rand(1:1000))
        d = UInt64(rand(0:1_000_000))
        (p, d, d + UInt64(rand(0:100)) * p + UInt64(rand(0:1000)))
    end
    # `findfirst` reports one offending draw instead of up to two hundred failures.
    @test findfirst(!on_grid, draws) === nothing
end

@testset "a long refresh neither shifts the clock nor fires a burst of refreshes" begin
    period = UInt64(100_000_000)  # 100 ms, as a caller gets
    backend = ClockBackend(; long=2, pause=0.15)  # one refresh overruns by half
    MCMCProgress.display_run(run -> sleep(1.2), "Sampling mymodel", 1, backend, period)

    times = refresh_times(backend)
    @test length(times) >= 4

    # Refreshes stay on the grid the first one set; a drifting clock would miss
    # by 50 ms each time. The median and a loose bound tolerate a busy machine.
    offgrid = map(times[(begin+1):end]) do t
        remainder = (t - times[begin]) % period
        min(remainder, period - remainder)
    end
    @test middling(offgrid) < period ÷ 3

    # Skipped deadlines keep every gap close to a whole period.
    gaps = diff(times)
    @test minimum(gaps) > period ÷ 2
end

@testset "a refresh period must be positive" begin
    backend = MCMCProgress.RecordingBackend()
    @test_throws "a refresh period must be positive" MCMCProgress.display_run(
        run -> nothing,
        "Sampling mymodel",
        1,
        backend,
        UInt64(0),
    )
end

@testset "chains reporting on their own tasks are all displayed and all ended" begin
    nchains = 4
    total = 50
    backend = MCMCProgress.RecordingBackend()

    quick_run(backend; nchains) do run
        @sync for j in 1:nchains
            Threads.@spawn begin
                c = chain_at(run, j)
                step = open_phase!(c, "Finding step size", Binary())
                sleep(TEST_PERIOD / 1e9)
                close_phase!(step)
                warmup = open_phase!(c, "Warmup", Determinate(total))
                for i in 1:total
                    advance!(warmup, i)
                    sleep(TEST_PERIOD / 1e9 / 10)
                end
                close_phase!(warmup)
            end
        end
    end

    final = final_snapshot(backend)
    @test [c.outcome for c in final.chains] == fill(finished, nchains)
    for c in final.chains
        @test [p.name for p in c.phases] == ["Finding step size", "Warmup"]
        @test last(c.phases).position == total
        @test all(p -> p.closed isa UInt64, c.phases)
    end

    # Every chain's phases are announced, each against its own chain index.
    for j in 1:nchains
        opened = [
            call[3].name for
            call in backend.calls if call[1] === :phase_opened && call[2] == j
        ]
        closed = [
            call[3].name for
            call in backend.calls if call[1] === :phase_closed && call[2] == j
        ]
        @test opened == ["Finding step size", "Warmup"]
        @test closed == ["Finding step size", "Warmup"]
    end
end
