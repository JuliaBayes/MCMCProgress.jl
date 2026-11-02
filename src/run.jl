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

    function RunProgress(label::AbstractString, nchains::Integer)
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

`diagnostics` is `nothing` or an owned collection of per-chain named tuples.
Backends must treat the snapshot and its diagnostic values as read-only.
"""
struct RunSnapshot{D}
    label::String
    chains::Tuple{Vararg{ChainSnapshot}}
    diagnostics::D
end
RunSnapshot(label, chains) = RunSnapshot{Nothing}(label, chains, nothing)
RunSnapshot(r::RunProgress) = RunSnapshot(r.label, map(ChainSnapshot, r.chains))

_with_diagnostics(snapshot::RunSnapshot, ::Nothing) = snapshot
function _with_diagnostics(snapshot::RunSnapshot, diagnostics)
    rows = _copy_diagnostics(diagnostics())
    length(rows) == length(snapshot.chains) ||
        throw(ArgumentError("diagnostics must return one named tuple per chain"))
    return RunSnapshot(snapshot.label, snapshot.chains, rows)
end

_copy_diagnostics(rows::Tuple{Vararg{NamedTuple}}) = rows
_copy_diagnostics(rows::AbstractVector{<:NamedTuple}) = collect(rows)
_copy_diagnostics(rows::AbstractVector) = map(row -> row::NamedTuple, collect(rows))

_chain_diagnostics(snapshot::RunSnapshot{Nothing}, index) = nothing
_chain_diagnostics(snapshot::RunSnapshot, index) = snapshot.diagnostics[index]
_diagnostics_text(::Nothing) = ""
function _diagnostics_text(row::NamedTuple)
    text = join(("$name=$value" for (name, value) in pairs(row)), ", ")
    return replace(text, '\n' => ' ', '\r' => ' ', '\t' => ' ')
end

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
