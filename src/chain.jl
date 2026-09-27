"""
    ChainProgress

The state of one chain within an MCMC run.

$(TYPEDFIELDS)
"""
struct ChainProgress
    "The index of this chain within the run. Chain indices always begin at 1."
    index::Int
    "The phases of this chain, in the order they were opened. Note that this has to have an
    abstract element type since we may push arbitrary `Phase` objects into it."
    phases::Vector{Phase}
    "How this chain ended, or `nothing` if it is still running."
    outcome::Ref{Union{Outcome,Nothing}}
    "A chain-specific lock that protects reads and writes to the chain's mutable state."
    lock::ReentrantLock

    function ChainProgress(index::Int)
        return new(index, Phase[], Ref(nothing), ReentrantLock())
    end
end

"""
    open_phase!(c::ChainProgress, name::AbstractString, kind::PhaseKind) -> Phase

Open a phase called `name` on chain `c`, record its opening time, and return it.

A chain runs one phase at a time, so opening a phase while another is still open
is an error, as is opening one on a chain that has already been given an
outcome.

```julia
p = open_phase!(c, "Warmup", Determinate(1000))
```
"""
function open_phase!(c::ChainProgress, name::AbstractString, kind::PhaseKind)
    phase = Phase(name, kind, c.lock)
    lock(c.lock) do
        c.outcome[] === nothing || throw(
            ArgumentError(
                "chain $(c.index) has already ended (outcome $(c.outcome[]))",
            ),
        )
        i = findlast(isopen, c.phases)
        i === nothing || throw(
            ArgumentError(
                "chain $(c.index) still has an open phase (`$(c.phases[i].name)`)",
            ),
        )
        push!(c.phases, phase)
    end
    return phase
end

function close_open_phases!(c::ChainProgress)
    at = time_ns()
    lock(c.lock) do
        for p in c.phases
            isopen(p) && close!(p, at)
        end
    end
    return nothing
end

function set_outcome!(c::ChainProgress, outcome::Outcome)
    lock(c.lock) do
        c.outcome[] === nothing || throw(
            ArgumentError(
                "chain $(c.index) has already ended as $(c.outcome[])",
            ),
        )
        c.outcome[] = outcome
    end
    return outcome
end

"""
    ChainSnapshot

An immutable copy of a `ChainProgress` at a given instant.
"""
struct ChainSnapshot
    index::Int
    phases::Tuple{Vararg{PhaseSnapshot}}
    outcome::Union{Outcome,Nothing}

    function ChainSnapshot(c::ChainProgress)
        return lock(c.lock) do
            ChainSnapshot(c.index, map(PhaseSnapshot, c.phases), c.outcome)
        end
    end
end

function Base.show(io::IO, c::ChainSnapshot)
    print(io, "ChainSnapshot(", c.index, ", ", length(c.phases), " phase")
    length(c.phases) == 1 || print(io, "s")
    c.outcome === nothing || print(io, ", ", c.outcome)
    print(io, ")")
end
