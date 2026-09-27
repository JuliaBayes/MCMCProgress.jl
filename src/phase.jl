# Concurrency
#
# A chain is written to by the task running it and read by the task refreshing
# the display, so the two overlap in time. The rules:
#
#   * A phase's `position` is atomic. `advance!` stores to it with monotonic
#     (relaxed) ordering and takes no lock; a reader that sees a stale position
#     draws a stale position, and nothing else follows from it.
#   * Everything structural — which phases a chain has opened, whether a phase is
#     still open and when it closed, and the chain's outcome — is written and
#     read only while the chain's `lock` is held. `Phase.lock` is the lock of the
#     chain that owns the phase, so one lock guards a chain and all its phases.
#   * `Phase.open` is the one piece of structural state also readable without the
#     lock, and is atomic for that reason: `advance!` has to reject a closed
#     phase without taking a lock. The closing time it accompanies is read under
#     the lock.
#
# One task at a time opens, advances and closes the phases of any one chain.
# Other tasks only read, or act after that task has ended.
#
# Two properties a snapshot relies on:
#
#   * A phase is never seen half-built: it is fully constructed before the lock
#     is taken and appended to the chain while the lock is held.
#   * A phase seen as closed carries the last position stored before it closed.
#     Releasing the lock publishes every earlier write by the reporting task, the
#     relaxed store of the position included.

"""
    Phase{K<:PhaseKind}

The mutable state of one phase on one chain.
"""
mutable struct Phase{K<:PhaseKind}
    name::String
    kind::K
    "A representation of how far this phase has progressed. For `Determinate` and `Counting`
    phases, it is the number of iterations completed. For a `Binary` phase, it is always
    zero."
    @atomic position::Int
    "The time the phase opened, in nanoseconds since some machine-specific arbitrary time in
    the past (this is the output of `Base.time_ns`)."
    opened::UInt64
    "The time the phase closed, or `nothing` if it is still open."
    closed::Union{UInt64,Nothing}
    "Whether or not the phase is still open."
    @atomic open::Bool
    "The lock of the chain that this phase belongs to."
    lock::ReentrantLock

    Phase(name::String, kind::K, lock::ReentrantLock) where {K<:PhaseKind} =
        new{K}(name, kind, 0, time_ns(), nothing, true, lock)
end

"""
    isopen(phase::Phase) -> Bool

Whether `phase` is still open.
"""
Base.isopen(p::Phase) = @atomic :monotonic p.open

"""
    advance!(phase::Phase, i::Int)

Record that `phase` has reached the absolute position `i`.
"""
advance!(::Phase{Binary}, ::Int) = nothing
function advance!(p::Phase{Counting}, i::Int)
    i >= 0 || throw(
        ArgumentError(
            "a position cannot be negative, so the phase \"$(p.name)\" cannot advance to $i",
        ),
    )
    return set_position!(p, i)
end
function advance!(p::Phase{Determinate}, i::Int)
    total = p.kind.total
    0 <= i <= total || throw(
        ArgumentError(
            "the phase \"$(p.name)\" runs for $total iterations, so it cannot advance to $i",
        ),
    )
    return set_position!(p, i)
end

function set_position!(p::Phase, i::Int)
    isopen(p) || throw(ArgumentError("the phase \"$(p.name)\" is closed"))
    @atomic :monotonic p.position = i
    return nothing
end

"""
    close_phase!(phase::Phase) -> Phase

Record that `phase` is over.

A closed phase keeps the position it last reached and cannot be advanced or closed again.
"""
function close_phase!(p::Phase)
    lock(p.lock) do
        isopen(p) || throw(ArgumentError("the phase \"$(p.name)\" has already been closed"))
        p.closed = time_ns()
        @atomic :monotonic p.open = false
    end
    return p
end

"""
    PhaseSnapshot{K<:PhaseKind}

An immutable copy of a phase's state at one instant.

On top of all the information already present in the `Phase`, we need to additionally track
the `objectid` of the phase in order to disambiguate phases which have the same name and
kind.
"""
struct PhaseSnapshot{K<:PhaseKind,C<:Union{UInt64,Nothing}}
    id::UInt
    name::String
    kind::K
    position::Int
    opened::UInt64
    closed::C
end
function PhaseSnapshot(p::Phase{K}) where {K<:PhaseKind}
    return lock(p.lock) do
        closed = p.closed
        PhaseSnapshot{K,typeof(closed)}(
            objectid(p),
            p.name,
            p.kind,
            (@atomic :monotonic p.position),
            p.opened,
            closed,
        )
    end
end

_position_text(p::PhaseSnapshot{Determinate}) = string(p.position, "/", p.kind.total)
_position_text(p::PhaseSnapshot{Counting}) = string(p.position)
_position_text(::PhaseSnapshot{Binary}) = nothing

function Base.show(io::IO, p::PhaseSnapshot)
    state = p.closed === nothing ? "open" : "closed"
    print(io, "PhaseSnapshot(", repr(p.name), ", ", p.kind, ", ", state)
    position = _position_text(p)
    position === nothing || print(io, ", ", position)
    print(io, ")")
end
