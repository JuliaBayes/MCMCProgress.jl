# The lifetime of a run: `progress` creates the run, refreshes the backend on a
# fixed clock while the body reports, and tears the backend down however the
# body ends.
#
# Which task calls the backend
#
# While the body runs, only the refresh task calls the backend. `open_phase!`,
# `advance!` and `close_phase!` never call it; the refresh task compares each
# snapshot with what it has already announced. A backend therefore needs no
# locking. The final calls of a run come from the task that called `progress`,
# after the refresh task has stopped.

"""
    REFRESH_PERIOD

Nanoseconds between refreshes: 100 ms, the frame period of the fastest spinner a
terminal display animates.

Reporting does not follow this period: a chain records a position with a single
atomic store, so the cost of drawing does not grow with how often, or how many,
chains report.
"""
const REFRESH_PERIOD = UInt64(100_000_000)

"""
    Announced(nchains)

How many of each chain's phases the backend has been told about: `opened[j]` and
`closed[j]` count the phases of chain `j` that have been passed to
[`phase_opened`](@ref) and [`phase_closed`](@ref).

A chain only appends phases and closes each before opening the next, so in a
new snapshot the phases after `opened[j]` have not been announced as opened, and
the closed phases after `closed[j]` have not been announced as closed.
"""
struct Announced
    opened::Vector{Int}
    closed::Vector{Int}
end

Announced(nchains::Integer) = Announced(zeros(Int, nchains), zeros(Int, nchains))

"""
    announce!(handle, state::RunSnapshot, announced::Announced)

Call [`phase_opened`](@ref) and [`phase_closed`](@ref) for every phase in `state`
not yet announced, chain by chain in opening order, and update `announced`.

A phase that opens and closes between two refreshes is announced as opened and
then as closed from the same snapshot, so both calls receive the phase in its
closed state.
"""
function announce!(handle, state::RunSnapshot, announced::Announced)
    for (j, chain) in pairs(state.chains)
        for (k, phase) in pairs(chain.phases)
            if k > announced.opened[j]
                phase_opened(handle, chain.index, phase)
                announced.opened[j] = k
            end
            if k > announced.closed[j] && phase.closed !== nothing
                phase_closed(handle, chain.index, phase)
                announced.closed[j] = k
            end
        end
    end
    return nothing
end

"""
    next_deadline(deadline, period, now) -> UInt64

The refresh time following `deadline`, as a [`time_ns`](@ref) reading: the
earliest time later than `now` on the grid of times `period` apart that runs
through `deadline`.

Staying on the grid prevents drift: a refresh that overruns its deadline skips
the deadlines that passed while it ran rather than firing once for each, and
later refreshes stay on schedule.
"""
function next_deadline(deadline::UInt64, period::UInt64, now::UInt64)
    next = deadline + period
    next > now && return next
    return next + ((now - next) ÷ period + 1) * period
end

# Snapshot the run, announce what is new, and draw it, once every `period`
# nanoseconds until `stop` is set. The flag is read again after the wait, so a
# run that ends while this task sleeps draws nothing more; the teardown draws the
# final state.
#
# A failure is logged as soon as it happens, because nobody waits on this task
# until the run ends, and then rethrown so that the run reports it again there.
function refresh_loop(
    run::Run,
    handle,
    announced::Announced,
    period::UInt64,
    stop::Threads.Atomic{Bool},
)
    try
        deadline = time_ns() + period
        while !stop[]
            now = time_ns()
            now < deadline && sleep((deadline - now) / 1e9)
            stop[] && break
            state = snapshot(run)
            announce!(handle, state, announced)
            refresh(handle, state)
            deadline = next_deadline(deadline, period, time_ns())
        end
    catch exception
        @error "A progress display failed while refreshing; sampling continues without a display." exception =
            (exception, catch_backtrace())
        rethrow()
    end
    return nothing
end

# The refresh task runs on an interactive thread if the session has one, so
# sampling work filling the default pool does not delay the display.
function spawn_refresh(
    run::Run,
    handle,
    announced::Announced,
    period::UInt64,
    stop::Threads.Atomic{Bool},
)
    pool = Threads.threadpoolsize(:interactive) > 0 ? :interactive : :default
    return Threads.@spawn pool refresh_loop(run, handle, announced, period, stop)
end

"""
    progress(f; label, nchains, backend=nothing)

Display the progress of a run of `nchains` chains called `label` while `f(run)`
samples, and return whatever `f` returns.

`f` is handed the run to report on: [`chain`](@ref) reaches one of its chains,
and [`open_phase!`](@ref), [`advance!`](@ref) and [`close_phase!`](@ref) report
that chain's progress. Chains may run on separate tasks, each reporting on its
own.

`backend` selects the display. If it is omitted, the default set by
[`set_backend!`](@ref) is used, or [`PlainTextBackend`](@ref) if none is set.

A separate task refreshes the backend every [`REFRESH_PERIOD`](@ref)
nanoseconds. Recording a position never waits for the display.

However `f` ends, any phase left open is closed, every chain still running is
given an outcome, the refresh task stops, and the backend's [`teardown`](@ref)
is called, which is where a terminal display restores the cursor. An exception
from `f` is rethrown unchanged and ends the chains still running as `failed`, or
as `interrupted` for an `InterruptException`.

If the backend throws while refreshing, the error is logged at once and the
display stops, but `f` keeps running; the failure is thrown again when `f`
returns.

`f` must wait for every task it spawns before returning, as `@sync` does below. A
task still reporting after `progress` returns finds its phase closed, and its
next [`advance!`](@ref) throws an error that nothing observes.

Ctrl-C delivers an `InterruptException` to the main task. It reaches `f` only when
`progress` is called from the main task, as it is at the REPL. It does not stop
the tasks `f` spawned: when the interrupt leaves a `@sync` block, those tasks keep
running, and the next report each one makes throws, which is what stops them.
When the session has interactive threads, the refresh task runs on that pool,
which includes the main thread, so an interrupt can occasionally reach the
refresh task instead of `f`; it then appears as a display failure and `f` keeps
running.

```julia
progress(; label="Sampling mymodel", nchains=4) do run
    @sync for j in 1:4
        Threads.@spawn begin
            c = chain_at(run, j)
            p = open_phase!(c, "Warmup", Determinate(1000))
            for i in 1:1000
                warmup_step()
                advance!(p, i)
            end
            close_phase!(p)
        end
    end
end
```
"""
progress(f; label::AbstractString, nchains::Integer, backend=nothing) =
    display_run(f, label, nchains, backend, REFRESH_PERIOD)

# `progress` with an explicit refresh period.
function display_run(f, label::AbstractString, nchains::Integer, backend, period::UInt64)
    period > 0 ||
        throw(ArgumentError("a refresh period must be positive, got $period nanoseconds"))
    run = Run(label, nchains)
    # A failure in `setup` leaves nothing to finish off: there is no handle yet.
    handle = setup(resolve_backend(backend), snapshot(run))
    announced = Announced(length(run.chains))
    stop = Threads.Atomic{Bool}(false)
    task = spawn_refresh(run, handle, announced, period, stop)
    result = try
        f(run)
    catch exception
        outcome = exception isa InterruptException ? interrupted : failed
        end_run!(run, handle, announced, task, stop, outcome, exception)
        rethrow()
    end
    end_run!(run, handle, announced, task, stop, finished, nothing)
    return result
end

"""
    end_run!(run, handle, announced, task, stop, outcome, cause)

End a run's display: close every phase the run left open, give `outcome` to
every chain that has not ended yet, stop the refresh task, and tear the backend
down. Every step runs even if an earlier one throws, so the display is never
left half torn down.

`cause` is the exception that ended the run's body, or `nothing` if the body
returned normally. With a `cause`, which the caller rethrows, every failure here
is logged. Without one, the first failure is rethrown with its backtrace once the
later steps have run, and any later failure is logged.

The backend is called only once the refresh task has finished. An interrupt that
lands while waiting for it leaves it running; the backend is then not called
again, and each call skipped is a failure in its own right.
"""
function end_run!(
    run::Run,
    handle,
    announced::Announced,
    task::Task,
    stop::Threads.Atomic{Bool},
    outcome::Outcome,
    cause,
)
    steps = [
        "closing the phases the run left open" =>
            () -> foreach(close_open_phases!, run.chains),
        "recording how the chains ended" =>
            () -> foreach(run.chains) do c
                # One lock covers the read and the write, so a chain that recorded
                # its own outcome keeps it.
                lock(c.lock) do
                    c.outcome === nothing && set_outcome!(c, outcome)
                end
            end,
        "stopping the refresh task" => () -> begin
            stop[] = true
            # Rethrows any exception that ended the refresh task.
            wait(task)
        end,
        # Every chain has ended and the refresh task has stopped, so the two
        # snapshots below show the same state.
        "announcing the phases that closed as the run ended" =>
            () -> begin
                require_stopped(task)
                announce!(handle, snapshot(run), announced)
            end,
        "tearing the backend down" => () -> begin
            require_stopped(task)
            teardown(handle, snapshot(run))
        end,
    ]
    run_teardown_steps(steps, cause)
    return nothing
end

function require_stopped(task::Task)
    istaskdone(task) ||
        error("the refresh task was still running, so the backend was not called")
    return nothing
end

# Run every step in order, even after one throws. Without a `cause`, the first
# failure is rethrown from its own `catch` block, which keeps its backtrace, after
# the later steps have run; every other failure is logged.
function run_teardown_steps(steps::AbstractVector{<:Pair}, cause)
    for (i, (what, step)) in pairs(steps)
        try
            step()
        catch exception
            if cause === nothing
                run_teardown_steps(steps[(i+1):end], exception)
                rethrow()
            end
            @error "A progress display failed while $what." exception =
                (exception, catch_backtrace())
        end
    end
    return nothing
end
