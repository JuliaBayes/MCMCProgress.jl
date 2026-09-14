# The lifetime of a run: `progress` creates the run, drives the active backend on
# a fixed clock while the body reports, and tears the backend down however the
# body ends.
#
# Which task calls the backend
#
# Every call into the backend comes from the refresh task, never from a task that
# is reporting: the reporting verbs in `report.jl` know nothing of backends, and
# the refresh task works out what to tell the backend by comparing each snapshot
# with what it has announced so far. A backend therefore needs no locking of its
# own. The last few calls of a run are made by the task that called `progress`,
# after the refresh task has stopped, so those cannot overlap with it either.

"""
    REFRESH_PERIOD

Nanoseconds between refreshes: 100 ms, the frame period of the fastest spinner a
terminal display animates.

Reporting is not paced by this: a chain records a position with a single atomic
store, so the cost of drawing does not depend on how fast or how many chains
report.
"""
const REFRESH_PERIOD = UInt64(100_000_000)

"""
    Announced(nchains)

How many of each chain's phases the backend has been told about: `opened[j]` and
`closed[j]` count the phases of chain `j` that have been passed to
[`phase_opened`](@ref) and [`phase_closed`](@ref).

A chain's phases only ever grow at the end, and a chain closes each phase before
opening the next, so these two counts say what a fresh snapshot adds: the phases
after `opened[j]` have not been announced as opened, and those after `closed[j]`
carrying a closing time have not been announced as closed.
"""
struct Announced
    opened::Vector{Int}
    closed::Vector{Int}
end

Announced(nchains::Integer) = Announced(zeros(Int, nchains), zeros(Int, nchains))

"""
    announce!(handle, state::RunSnapshot, announced::Announced)

Tell the backend about every phase in `state` it has not heard of yet, chain by
chain and in the order each chain opened them, and record what it has been told.

A phase that opens and closes between one refresh and the next is announced as
opened and then as closed from the one snapshot that first shows it, so a short
phase is still announced. Both calls carry that snapshot, which is the phase as
it now stands rather than as it stood when it opened.
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
    nextdeadline(deadline, period, now) -> UInt64

The refresh time following `deadline`, as a [`time_ns`](@ref) reading: the
earliest time later than `now` on the grid of times `period` apart that runs
through `deadline`.

Holding to that grid keeps the clock from sliding: a refresh that overruns its
deadline skips the deadlines that passed while it ran rather than firing once for
each, and the refreshes after it land where they would have landed anyway.
"""
function nextdeadline(deadline::UInt64, period::UInt64, now::UInt64)
    next = deadline + period
    next > now && return next
    return next + ((now - next) ÷ period + 1) * period
end

# Snapshot the run, announce what is new, and draw it, once every `period`
# nanoseconds until `stop` is set. The flag is read again after the wait, so a
# run that ends while this task sleeps draws nothing further: the final state is
# drawn by the teardown, on the task that called `progress`.
function refreshloop(
    run::Run,
    handle,
    announced::Announced,
    period::UInt64,
    stop::Threads.Atomic{Bool},
)
    deadline = time_ns() + period
    while !stop[]
        now = time_ns()
        now < deadline && sleep((deadline - now) / 1e9)
        stop[] && break
        state = snapshot(run)
        announce!(handle, state, announced)
        refresh(handle, state)
        deadline = nextdeadline(deadline, period, time_ns())
    end
    return nothing
end

# The refresh task runs on an interactive thread where the session has one, so
# that sampling work saturating the default pool does not hold up the display. A
# session started without interactive threads gets the default pool, where a task
# that sleeps between refreshes still wakes, if less regularly.
function spawnrefresh(
    run::Run,
    handle,
    announced::Announced,
    period::UInt64,
    stop::Threads.Atomic{Bool},
)
    pool = Threads.threadpoolsize(:interactive) > 0 ? :interactive : :default
    return Threads.@spawn pool refreshloop(run, handle, announced, period, stop)
end

"""
    progress(f; label, nchains, backend=nothing)

Display the progress of a run of `nchains` chains called `label` while `f(run)`
samples, and return whatever `f` returns.

`f` is handed the run to report on: [`chain`](@ref) reaches one of its chains,
and [`openphase!`](@ref), [`advance!`](@ref) and [`closephase!`](@ref) report
that chain's progress. Chains may run on separate tasks, each reporting on its
own.

`backend` is the display to drive. Left out, the process-wide default set by
[`setbackend!`](@ref) is used, and failing that plain text.

The backend is refreshed every [`REFRESH_PERIOD`](@ref) nanoseconds from a task
of its own, whatever the chains are doing. Recording a position never waits for
the display.

However `f` ends, the display is finished off: any phase left open is closed,
every chain still running is given an outcome, the refresh task stops, and the
backend's [`teardown`](@ref) is called, which is where a terminal display
restores the cursor. An exception from `f` reaches the caller unchanged and ends
the chains still running as `failed`, or as `interrupted` for an
`InterruptException`, which is what Ctrl-C delivers to the task running `f`.

```julia
progress(; label="Sampling mymodel", nchains=4) do run
    @sync for j in 1:4
        Threads.@spawn begin
            c = chain(run, j)
            p = openphase!(c, "Warmup", Determinate(1000))
            for i in 1:1000
                warmup_step()
                advance!(p, i)
            end
            closephase!(p)
        end
    end
end
```
"""
progress(f; label::AbstractString, nchains::Integer, backend=nothing) =
    displayrun(f, label, nchains, backend, REFRESH_PERIOD)

# `progress` with the refresh period spelled out, which is how a test drives a
# run faster than the clock a caller gets.
function displayrun(f, label::AbstractString, nchains::Integer, backend, period::UInt64)
    period > 0 ||
        throw(ArgumentError("a refresh period must be positive, got $period nanoseconds"))
    run = Run(label, nchains)
    # A failure in `setup` leaves nothing to finish off: there is no handle yet.
    handle = setup(resolve_backend(backend), snapshot(run))
    announced = Announced(length(run.chains))
    stop = Threads.Atomic{Bool}(false)
    task = spawnrefresh(run, handle, announced, period, stop)
    result = try
        f(run)
    catch exception
        outcome = exception isa InterruptException ? interrupted : failed
        endrun!(run, handle, announced, task, stop, outcome, exception)
        rethrow()
    end
    endrun!(run, handle, announced, task, stop, finished, nothing)
    return result
end

"""
    endrun!(run, handle, announced, task, stop, outcome, cause)

Finish off a run's display: close every phase the run left open, give `outcome`
to every chain that has not ended yet, stop the refresh task, and tear the
backend down. Every step runs whatever the steps before it did, since a display
left half torn down hides what the run was reporting.

`cause` is the exception that ended the run's body, or `nothing` if the body
returned normally, and it decides what becomes of an exception raised by a step
here. With a `cause`, the caller is about to rethrow that exception, so a step's
failure is logged rather than thrown over the top of it. Without one, the first
step to fail throws and any later failure is logged.
"""
function endrun!(
    run::Run,
    handle,
    announced::Announced,
    task::Task,
    stop::Threads.Atomic{Bool},
    outcome::Outcome,
    cause,
)
    problems = Any[]

    attempt!(problems, "closing the phases the run left open") do
        for c in run.chains
            closeopenphases!(c)
        end
    end

    attempt!(problems, "recording how the chains ended") do
        for c in run.chains
            # One hold of the lock covers both reading and writing the outcome,
            # so a chain that recorded its own keeps it.
            lock(c.lock) do
                c.outcome === nothing && setoutcome!(c, outcome)
            end
        end
    end

    attempt!(problems, "stopping the refresh task") do
        stop[] = true
        # Waiting, rather than only asking it to stop, is what keeps a refresh
        # from landing after this, and surfaces an exception the refresh task
        # died of.
        wait(task)
    end

    # Every chain has ended and the refresh task has stopped, so the two
    # snapshots below show the same state.
    attempt!(problems, "announcing the phases that closed as the run ended") do
        announce!(handle, snapshot(run), announced)
    end

    attempt!(problems, "tearing the backend down") do
        teardown(handle, snapshot(run))
    end

    report!(problems, cause)
    return nothing
end

# Run one step of the teardown, recording an exception it raises so that the
# steps after it still run.
function attempt!(step, problems::Vector, what::AbstractString)
    try
        step()
    catch exception
        push!(problems, (; what, exception, backtrace=catch_backtrace()))
    end
    return nothing
end

# Account for what the teardown ran into: every problem is logged, except one
# that is about to be thrown and so will reach the caller in full.
function report!(problems::Vector, cause)
    logged = cause === nothing ? firstindex(problems) + 1 : firstindex(problems)
    for i in logged:lastindex(problems)
        problem = problems[i]
        @error "A progress display failed while $(problem.what)." exception =
            (problem.exception, problem.backtrace)
    end
    cause === nothing && !isempty(problems) && throw(problems[begin].exception)
    return nothing
end
