"""
    RunProgress

The mutable state of an MCMC run.

$(TYPEDFIELDS)
"""
struct RunProgress{C<:Tuple{Vararg{ChainProgress}}}
    "A label for the entire run, e.g. the name of the model being sampled."
    label::String
    "The progress of each chain in the run."
    chains::C

    function RunProgress(label::String, nchains::Integer)
        chains = ntuple(i -> ChainProgress(i), nchains)
        return new{typeof(chains)}(label, chains)
    end
end

"""
    chain_at(run::RunProgress, i::Integer) -> ChainProgress

Get the progress object for the `i`-th chain in `run`.
"""
chain_at(run::RunProgress, index::Integer) = run.chains[index]

"""
    num_chains(run::Run) -> Int

The number of chains in `run`.
"""
num_chains(run::RunProgress) = length(run.chains)

"""
    chains(run::Run) -> Vector{ChainProgress}

All the progress items for the chains in `run`.
"""
chains(run::RunProgress) = run.chains

"""
    RunSnapshot

An immutable copy of a `RunProgress` at a given instant.
"""
struct RunSnapshot
    label::String
    chains::Tuple{Vararg{ChainSnapshot}}
end
RunSnapshot(r::RunProgress) = RunSnapshot(r.label, map(ChainSnapshot, r.chains))

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
