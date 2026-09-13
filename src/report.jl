# How a sampler reports its progress: reach a chain, open a phase on it, advance
# the phase, close it. The locking these calls obey is set out at the top of
# `live.jl`.

"""
    chain(run::Run, index::Integer) -> Chain

The chain at `index` within `run`. A run's chains are fixed when it is created,
so this is a plain lookup that no other task can be in the middle of changing.

```julia
c = chain(run, j)
```
"""
function chain(run::Run, index::Integer)
    chains = run.chains
    checkbounds(Bool, chains, index) || throw(
        ArgumentError("this run has $(length(chains)) chains, so there is no chain $index"),
    )
    return chains[index]
end

"""
    openphase!(c::Chain, name::AbstractString, kind::PhaseKind) -> Phase

Announce that chain `c` has entered a new phase called `name`, and return the
phase to advance and close. The opening time is stamped as the phase is created.

A chain runs one phase at a time, so opening a phase while another is still open
is an error, as is opening one on a chain that has already been given an
outcome.

```julia
p = openphase!(c, "Warmup", Determinate(1000))
```
"""
function openphase!(c::Chain, name::AbstractString, kind::PhaseKind)
    phase = Phase(name, kind, c.lock)
    lock(c.lock) do
        c.outcome === nothing || throw(
            ArgumentError(
                "chain $(c.index) has already ended as $(c.outcome), so it cannot open the phase \"$name\"",
            ),
        )
        i = findlast(isopen, c.phases)
        i === nothing || throw(
            ArgumentError(
                "chain $(c.index) still has the phase \"$(c.phases[i].name)\" open; close it before opening \"$name\"",
            ),
        )
        push!(c.phases, phase)
    end
    return phase
end

"""
    advance!(phase::Phase, i::Integer)

Record that `phase` has reached position `i`. The position is absolute: `i`
replaces whatever the position was, rather than being added to it, so a report
that is duplicated or dropped cannot make the position drift away from the
truth.

This is a single atomic store and takes no lock, which is what makes it cheap
enough to call on every iteration of a sampler.

On a `Binary` phase — one with no count at all — `advance!` does nothing, so
reporting code shared between phases of every kind need not ask what kind it
holds.

A `Determinate` phase cannot advance past the total it declared, no phase can
advance to a negative position, and a closed phase cannot advance at all. Each of
these is an error rather than a quietly corrected value, because each means the
reporting code and the phase disagree about what the phase is. None of them apply
to a `Binary` phase, which has no position to be wrong about.
"""
advance!(::Phase{Binary}, ::Integer) = nothing

function advance!(p::Phase{Counting}, i::Integer)
    i >= 0 || throw(
        ArgumentError(
            "a position cannot be negative, so the phase \"$(p.name)\" cannot advance to $i",
        ),
    )
    return setposition!(p, i)
end

function advance!(p::Phase{Determinate}, i::Integer)
    total = p.kind.total
    0 <= i <= total || throw(
        ArgumentError(
            "the phase \"$(p.name)\" runs for $total iterations, so it cannot advance to $i",
        ),
    )
    return setposition!(p, i)
end

function setposition!(p::Phase, i::Integer)
    isopen(p) || throw(
        ArgumentError("the phase \"$(p.name)\" is closed, so it cannot advance to $i"),
    )
    @atomic :monotonic p.position = Int(i)
    return nothing
end

"""
    closephase!(phase::Phase) -> Phase

Record that `phase` is over, stamping the closing time. A closed phase keeps the
position it last reached and cannot be advanced or closed again.
"""
function closephase!(p::Phase)
    lock(p.lock) do
        isopen(p) || throw(ArgumentError("the phase \"$(p.name)\" has already been closed"))
        close!(p, time_ns())
    end
    return p
end

# Stamp the closing time and withdraw the phase from reporting. The caller holds
# the phase's lock, which is what publishes the closing time to a snapshot.
# `open` is atomic because `advance!` reads it without taking that lock.
function close!(p::Phase, at::UInt64)
    p.closed = at
    @atomic :monotonic p.open = false
    return p
end

"""
    closeopenphases!(c::Chain)

Close every phase of `c` that is still open, stamping one closing time for all
of them. A chain with nothing open is left alone.

This is how a run's scope finishes off a phase whose caller never closed it,
whether because it forgot or because an exception unwound past the call.
"""
function closeopenphases!(c::Chain)
    at = time_ns()
    lock(c.lock) do
        for p in c.phases
            isopen(p) && close!(p, at)
        end
    end
    return nothing
end

"""
    setoutcome!(c::Chain, outcome::Outcome) -> Outcome

Record how chain `c` ended. A chain ends once, so setting an outcome on a chain
that already has one is an error.
"""
function setoutcome!(c::Chain, outcome::Outcome)
    lock(c.lock) do
        c.outcome === nothing || throw(
            ArgumentError(
                "chain $(c.index) has already ended as $(c.outcome), so it cannot also end as $outcome",
            ),
        )
        c.outcome = outcome
    end
    return outcome
end
