"""
    PhaseSnapshot{K<:PhaseKind}

An immutable copy of a phase's state at one instant: an identity distinct from
its name, plus the same name, kind, position, opening time, and closing time a
live [`Phase`](@ref) carries. Holds no reference back into live state.

`id` is what lets a backend key a bar on the phase itself rather than on its
name — two phases on one chain may share a name (a sampler that revisits
adaptation, say) and still be told apart by comparing `id`.
"""
struct PhaseSnapshot{K<:PhaseKind}
    id::UInt
    name::String
    kind::K
    position::Int
    opened::UInt64
    closed::Union{UInt64,Nothing}

    PhaseSnapshot{K}(id, name, kind, position, opened, closed) where {K<:PhaseKind} =
        new{K}(id, name, kind, position, opened, closed)
end

PhaseSnapshot(id, name::AbstractString, kind::PhaseKind, position, opened, closed) =
    PhaseSnapshot{typeof(kind)}(id, name, kind, position, opened, closed)

"""
    ChainSnapshot

An immutable copy of a chain's state at one instant: its index, its phases as
[`PhaseSnapshot`](@ref)s, and its outcome (`nothing` while still running). The
phases are held in a `Tuple`, so the snapshot cannot grow or shrink after it is
taken.
"""
struct ChainSnapshot
    index::Int
    phases::Tuple{Vararg{PhaseSnapshot}}
    outcome::Union{Outcome,Nothing}
end

ChainSnapshot(index::Integer, phases, outcome::Union{Outcome,Nothing}) =
    ChainSnapshot(Int(index), Tuple(phases), outcome)

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
    snapshot(p::Phase) -> PhaseSnapshot
    snapshot(c::Chain) -> ChainSnapshot
    snapshot(r::Run) -> RunSnapshot

Copy live state into an immutable picture of it. A chain's phases, their closure
and its outcome are read while the chain's lock is held, so the copy shows a
chain as it was at one instant: no phase appears half-opened, and a phase shown
as closed carries the position it finished on.

The chains of a run are copied one after another, each under its own lock, which
is what keeps a chain reporting on one task from waiting on a chain reporting on
another. A run snapshot is therefore a sequence of chains each caught at an
instant, rather than every chain caught at the same instant — a distinction with
no meaning for chains that run independently.
"""
function snapshot(p::Phase)
    return lock(p.lock) do
        PhaseSnapshot(
            objectid(p),
            p.name,
            p.kind,
            (@atomic :monotonic p.position),
            p.opened,
            p.closed,
        )
    end
end

function snapshot(c::Chain)
    return lock(c.lock) do
        ChainSnapshot(c.index, map(snapshot, c.phases), c.outcome)
    end
end

snapshot(r::Run) = RunSnapshot(r.label, map(snapshot, r.chains))
