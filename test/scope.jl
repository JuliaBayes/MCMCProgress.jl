# Backends that exist to be driven by a run rather than to draw anything, plus
# the shorter refresh clock the tests here run on.

"""
    ClockBackend(; long=0, pause=0.0)

Records the time each refresh begins, in `times`, and makes refresh number
`long` take `pause` seconds. `times` is guarded by `lock`, so a body can read it
while the refresh task is running; a refresh records its time before pausing, so
the recorded time is when the refresh began.
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

refreshcount(backend::ClockBackend) = lock(() -> length(backend.times), backend.lock)

refreshtimes(backend::ClockBackend) = lock(() -> copy(backend.times), backend.lock)

"""
    FailingBackend(failing::Symbol)

Records the name of every call it is given, in `calls`, and throws from the call
named `failing` — one of `:refresh`, `:phase_closed` or `:teardown`. A test reads
`calls` after the run has ended to see which calls still happened after one of
them threw.
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

# Twenty milliseconds, so a body of a tenth of a second sees several refreshes.
# A caller gets `MCMCProgress.REFRESH_PERIOD`; the tests here name their own
# clock to keep from waiting seconds for a handful of refreshes.
const TEST_PERIOD = UInt64(20_000_000)

quickrun(f, backend; nchains::Integer=1, period::UInt64=TEST_PERIOD) =
    MCMCProgress.displayrun(f, "Sampling mymodel", nchains, backend, period)

callnames(backend::MCMCProgress.RecordingBackend) = [call[1] for call in backend.calls]

finalsnapshot(backend::MCMCProgress.RecordingBackend) = last(backend.calls)[2]

# The middle value of `xs`, which says what the whole sequence does without one
# stray reading deciding it.
middling(xs) = sort(xs)[(length(xs)+1)÷2]

@testset "progress drives a backend from setup to teardown" begin
    backend = MCMCProgress.RecordingBackend()
    result = progress(; label="Sampling mymodel", nchains=2, backend=backend) do run
        c = chain(run, 1)
        p = openphase!(c, "Warmup", Determinate(10))
        advance!(p, 10)
        closephase!(p)
        :sampled
    end

    @test result === :sampled  # progress hands back whatever the body returns

    names = callnames(backend)
    @test first(names) === :setup
    @test last(names) === :teardown
    @test :phase_opened in names
    @test :phase_closed in names

    final = finalsnapshot(backend)
    @test [c.outcome for c in final.chains] == [finished, finished]
    @test final.chains[1].phases[1].position == 10
end

@testset "progress uses the process-wide default backend when given none" begin
    saved_default = MCMCProgress._DEFAULT_BACKEND[]
    try
        backend = MCMCProgress.RecordingBackend()
        setbackend!(backend)
        progress(; label="Sampling mymodel", nchains=1) do run
            nothing
        end
        @test first(callnames(backend)) === :setup
        @test last(callnames(backend)) === :teardown
    finally
        MCMCProgress._DEFAULT_BACKEND[] = saved_default
    end
end

@testset "phases are announced to the backend in the order a chain opens them" begin
    backend = MCMCProgress.RecordingBackend()
    quickrun(backend) do run
        c = chain(run, 1)
        step = openphase!(c, "Finding step size", Binary())
        closephase!(step)
        warmup = openphase!(c, "Warmup", Determinate(4))
        for i in 1:4
            advance!(warmup, i)
            sleep(TEST_PERIOD / 1e9)
        end
        closephase!(warmup)
    end

    announcements = [
        call for
        call in backend.calls if call[1] === :phase_opened || call[1] === :phase_closed
    ]
    # A phase that opens and closes between two refreshes is still announced
    # both times, in order, from the snapshot that first shows it.
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
    quickrun(backend) do run
        openphase!(chain(run, 1), "Warmup", Determinate(100))
        sleep(3 * TEST_PERIOD / 1e9)
        nothing
    end

    names = callnames(backend)
    @test last(names) === :teardown
    # The phase is announced as closed before the backend is torn down.
    @test findlast(==(:phase_closed), names) < findlast(==(:teardown), names)

    closing = last(call for call in backend.calls if call[1] === :phase_closed)
    @test closing[3].name == "Warmup"
    @test closing[3].closed isa UInt64

    phase = finalsnapshot(backend).chains[1].phases[1]
    @test phase.closed isa UInt64
    @test phase.closed >= phase.opened
end

@testset "an exception from the body reaches the caller unchanged" begin
    backend = MCMCProgress.RecordingBackend()
    blewup = ErrorException("the sampler blew up")

    caught = nothing
    try
        quickrun(backend; nchains=2) do run
            openphase!(chain(run, 1), "Warmup", Determinate(100))
            throw(blewup)
        end
    catch exception
        caught = exception
    end

    @test caught === blewup  # the same object, not a copy and not a wrapper

    # The display is still finished off, which is what leaves a terminal usable.
    @test last(callnames(backend)) === :teardown
    final = finalsnapshot(backend)
    @test [c.outcome for c in final.chains] == [failed, failed]
    @test final.chains[1].phases[1].closed isa UInt64
end

@testset "an InterruptException ends the chains as interrupted" begin
    backend = MCMCProgress.RecordingBackend()
    @test_throws InterruptException quickrun(backend; nchains=3) do run
        openphase!(chain(run, 2), "Warmup", Determinate(100))
        throw(InterruptException())
    end

    @test last(callnames(backend)) === :teardown
    final = finalsnapshot(backend)
    @test [c.outcome for c in final.chains] == [interrupted, interrupted, interrupted]
    @test final.chains[2].phases[1].closed isa UInt64
end

@testset "a chain that recorded its own outcome keeps it" begin
    backend = MCMCProgress.RecordingBackend()
    caught = nothing
    try
        quickrun(backend; nchains=2) do run
            MCMCProgress.setoutcome!(chain(run, 1), finished)
            error("the sampler blew up")
        end
    catch exception
        caught = exception
    end

    @test caught isa ErrorException
    @test [c.outcome for c in finalsnapshot(backend).chains] == [finished, failed]
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
                quickrun(body, backend)
            catch
                # Which exception reaches the caller is asserted elsewhere; what
                # matters here is what the backend is told, and when.
            end

            names = callnames(backend)
            # A tenth of a second on a twenty millisecond clock: several
            # refreshes are due, and one is asserted so that the rest of this
            # testset is not read as passing on a display that never ran.
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
        @test_throws "this backend cannot close a phase" quickrun(backend) do run
            openphase!(chain(run, 1), "Warmup", Determinate(100))
            nothing
        end
        @test :teardown in backend.calls
    end

    @testset "a backend that cannot refresh" begin
        backend = FailingBackend(:refresh)
        # The refresh task dies of the failure, which surfaces where the run
        # stops it rather than going unreported.
        @test_throws "this backend cannot refresh" quickrun(backend) do run
            sleep(0.1)
            nothing
        end
        @test :teardown in backend.calls
    end

    @testset "a backend that cannot tear down" begin
        backend = FailingBackend(:teardown)
        @test_throws "this backend cannot tear down" quickrun(backend) do run
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
            quickrun(backend) do run
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
    quickrun(backend) do run
        # Waiting for the display rather than for the clock: a test that hangs
        # here reports a refresh task that never runs, instead of hanging.
        @test timedwait(() -> refreshcount(backend) >= 3, 10.0) === :ok
        nothing
    end
end

@testset "the refresh task is spawned on the pool the session has threads for" begin
    run = MCMCProgress.Run("Sampling mymodel", 1)
    backend = MCMCProgress.RecordingBackend()
    stop = Threads.Atomic{Bool}(true)  # already stopped, so the loop draws nothing
    task = MCMCProgress.spawnrefresh(
        run,
        backend,
        MCMCProgress.Announced(1),
        TEST_PERIOD,
        stop,
    )
    wait(task)

    # An interactive thread wherever the session has one, so that sampling work
    # filling the default pool cannot hold the display up.
    expected = Threads.threadpoolsize(:interactive) > 0 ? :interactive : :default
    @test Threads.threadpool(task) === expected
    @test isempty(backend.calls)
end

@testset "the refresh clock stays on its grid when a refresh runs long" begin
    period = UInt64(100)
    deadline = UInt64(1000)

    # A refresh done before its deadline: the next is a whole period later.
    @test MCMCProgress.nextdeadline(deadline, period, deadline - UInt64(5)) ==
          deadline + period
    @test MCMCProgress.nextdeadline(deadline, period, deadline + UInt64(50)) ==
          deadline + period

    # A refresh still running when the next deadline falls due: that deadline is
    # skipped rather than fired late, and the one after it lands on the grid.
    @test MCMCProgress.nextdeadline(deadline, period, deadline + period) ==
          deadline + 2 * period
    @test MCMCProgress.nextdeadline(deadline, period, deadline + 3 * period + UInt64(1)) ==
          deadline + 4 * period

    # However long a refresh overruns, the deadline that follows is the earliest
    # one later than now on the grid that runs through the deadline it started
    # from: never earlier, never more than one period later, never off the grid.
    function ongrid((p, d, now))
        next = MCMCProgress.nextdeadline(d, p, now)
        return next > now && next <= now + p && (next - d) % p == 0
    end

    draws = map(1:200) do _
        p = UInt64(rand(1:1000))
        d = UInt64(rand(0:1_000_000))
        (p, d, d + UInt64(rand(0:100)) * p + UInt64(rand(0:1000)))
    end
    # The first offending draw, so a failure names the period, deadline and time
    # it came from rather than repeating across two hundred of them.
    @test findfirst(!ongrid, draws) === nothing
end

@testset "a long refresh neither shifts the clock nor fires a burst of refreshes" begin
    period = UInt64(100_000_000)  # 100 ms, as a caller gets
    backend = ClockBackend(; long=2, pause=0.15)  # one refresh overruns by half
    MCMCProgress.displayrun(run -> sleep(1.2), "Sampling mymodel", 1, backend, period)

    times = refreshtimes(backend)
    @test length(times) >= 4

    # Every refresh should fall on the grid the first one set, so the time by
    # which each misses the nearest grid point stays near zero. A clock that
    # slid by the overrun would miss by fifty milliseconds every time. The
    # middle reading is what is asserted, and the bound is generous, so that
    # neither one late wake-up nor a busy machine fails this.
    offgrid = map(times[(begin+1):end]) do t
        remainder = (t - times[begin]) % period
        min(remainder, period - remainder)
    end
    @test middling(offgrid) < period ÷ 3

    # Skipping the deadlines that passed during the long refresh, rather than
    # firing one refresh for each, keeps every gap close to a whole period.
    gaps = diff(times)
    @test minimum(gaps) > period ÷ 2
end

@testset "a refresh period must be positive" begin
    backend = MCMCProgress.RecordingBackend()
    @test_throws "a refresh period must be positive" MCMCProgress.displayrun(
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

    quickrun(backend; nchains) do run
        @sync for j in 1:nchains
            Threads.@spawn begin
                c = chain(run, j)
                step = openphase!(c, "Finding step size", Binary())
                sleep(TEST_PERIOD / 1e9)
                closephase!(step)
                warmup = openphase!(c, "Warmup", Determinate(total))
                for i in 1:total
                    advance!(warmup, i)
                    sleep(TEST_PERIOD / 1e9 / 10)
                end
                closephase!(warmup)
            end
        end
    end

    final = finalsnapshot(backend)
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
