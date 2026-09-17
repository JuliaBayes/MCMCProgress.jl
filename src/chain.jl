"""
    Chain

The live state of one chain: its index within the run, the ordered phases it has
opened so far, and its outcome once it has one (`nothing` while still running).

`lock` guards the phases and the outcome. It is held to open a phase, close one,
set the outcome, or read that state for a snapshot, and never while a position is
recorded.
"""
mutable struct Chain
    index::Int
    phases::Vector{Phase}
    outcome::Union{Outcome,Nothing}
    lock::ReentrantLock

    function Chain(
        index::Integer,
        phases::AbstractVector{<:Phase},
        outcome::Union{Outcome,Nothing},
        lock::ReentrantLock=ReentrantLock(),
    )
        for p in phases
            p.lock === lock || throw(
                ArgumentError(
                    "the phase \"$(p.name)\" holds a different lock from chain $index; a chain and its phases share one lock",
                ),
            )
        end
        new(Int(index), collect(Phase, phases), outcome, lock)
    end
end

"""
    Chain(index)

Create a chain at the given index with no phases opened yet.
"""
Chain(index::Integer) = Chain(index, Phase[], nothing)

"""
    open_phase!(c::Chain, name::AbstractString, kind::PhaseKind) -> Phase

Open a phase called `name` on chain `c`, record its opening time, and return it.

A chain runs one phase at a time, so opening a phase while another is still open
is an error, as is opening one on a chain that has already been given an
outcome.

```julia
p = open_phase!(c, "Warmup", Determinate(1000))
```
"""
function open_phase!(c::Chain, name::AbstractString, kind::PhaseKind)
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
    close_open_phases!(c::Chain)

Close every phase of `c` that is still open, stamping one closing time for all
of them. A chain with nothing open is left unchanged.
"""
function close_open_phases!(c::Chain)
    at = time_ns()
    lock(c.lock) do
        for p in c.phases
            isopen(p) && close!(p, at)
        end
    end
    return nothing
end

"""
    set_outcome!(c::Chain, outcome::Outcome) -> Outcome

Record how chain `c` ended. A chain ends once, so setting an outcome on a chain
that already has one is an error.
"""
function set_outcome!(c::Chain, outcome::Outcome)
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

"""
    ChainSnapshot

An immutable copy of a chain's state at one instant: its index, its phases as
[`PhaseSnapshot`](@ref)s, and its outcome (`nothing` while still running).
"""
struct ChainSnapshot
    index::Int
    phases::Tuple{Vararg{PhaseSnapshot}}
    outcome::Union{Outcome,Nothing}
end

ChainSnapshot(index::Integer, phases, outcome::Union{Outcome,Nothing}) =
    ChainSnapshot(Int(index), Tuple(phases), outcome)

"""
    snapshot(c::Chain) -> ChainSnapshot

Copy the state of `c` into a `ChainSnapshot`. The phases, their closing times and
the outcome are read under the chain's lock, so the snapshot shows the chain at a
single instant: no phase is half-built, and a closed phase carries its final
position.
"""
function snapshot(c::Chain)
    return lock(c.lock) do
        ChainSnapshot(c.index, map(snapshot, c.phases), c.outcome)
    end
end

function Base.show(io::IO, c::ChainSnapshot)
    print(io, "ChainSnapshot(", c.index, ", ", length(c.phases), " phase")
    length(c.phases) == 1 || print(io, "s")
    c.outcome === nothing || print(io, ", ", c.outcome)
    print(io, ")")
end
