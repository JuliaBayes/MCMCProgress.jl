"""
    Run

The live state of a run: its label and its fixed sequence of chains. The
sequence never changes, so reaching a chain needs no lock; the chain's own lock
guards everything inside it.
"""
struct Run
    label::String
    chains::Vector{Chain}

    function Run(label::AbstractString, chains::AbstractVector{Chain})
        isempty(chains) && throw(ArgumentError("a run must have at least one chain"))
        new(String(label), collect(Chain, chains))
    end
end

"""
    Run(label, nchains)

Create a run with `nchains` chains, indexed `1:nchains`. The number of chains is
fixed for the life of the run.
"""
Run(label::AbstractString, nchains::Integer) = Run(label, [Chain(i) for i in 1:nchains])

"""
    chain(run::Run, index::Integer) -> Chain

The chain at `index` within `run`. A run's chains are fixed when it is created,
so this lookup takes no lock.

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
    RunSnapshot

An immutable copy of a run's state at one instant: its label and its chains as
[`ChainSnapshot`](@ref)s. This is what a refresh hands to a backend to draw from.
"""
struct RunSnapshot
    label::String
    chains::Tuple{Vararg{ChainSnapshot}}
end

RunSnapshot(label::AbstractString, chains) = RunSnapshot(String(label), Tuple(chains))

"""
    snapshot(r::Run) -> RunSnapshot

Copy the state of `r` into a `RunSnapshot`. Chains are copied one at a time, each
under its own lock, so chains reporting on different tasks never wait on each
other. Each chain is captured at its own instant, not all at the same instant.
"""
snapshot(r::Run) = RunSnapshot(r.label, map(snapshot, r.chains))

function Base.show(io::IO, r::RunSnapshot)
    print(io, "RunSnapshot(", repr(r.label), ", ", length(r.chains), " chain")
    length(r.chains) == 1 || print(io, "s")
    print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", r::RunSnapshot)
    print(io, "Run ", repr(r.label), " (", length(r.chains), " chain")
    length(r.chains) == 1 || print(io, "s")
    print(io, ")")
    for c in r.chains
        print(io, "\n  ")
        show(io, c)
        for p in c.phases
            print(io, "\n    ")
            show(io, p)
        end
    end
end
