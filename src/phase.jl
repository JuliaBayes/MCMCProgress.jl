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

The live state of one phase on one chain: its name, kind, position, and the times
it opened and closed. `closed` is `nothing` while the phase is still open, and
`open` says the same thing in a form that can be read without the chain's lock.

`Phase` is mutable, so two phases with the same name, such as a repeated
adaptation phase, remain distinct objects. A `Binary` phase's position stays at
zero.

`lock` is the lock of the chain that owns the phase.
"""
mutable struct Phase{K<:PhaseKind}
    name::String
    kind::K
    @atomic position::Int
    opened::UInt64
    closed::Union{UInt64,Nothing}
    @atomic open::Bool
    lock::ReentrantLock

    Phase{K}(name, kind, position, opened, closed, lock) where {K<:PhaseKind} =
        new{K}(name, kind, position, opened, closed, closed === nothing, lock)
end

Phase(name::AbstractString, kind::PhaseKind, position, opened, closed, lock) =
    Phase{typeof(kind)}(name, kind, position, opened, closed, lock)

"""
    Phase(name, kind::PhaseKind, [lock])

Open a phase now: position starts at zero and the opening time is stamped with
[`time_ns`](@ref), a monotonic clock unaffected by wall-clock adjustments. A phase given
no lock gets one of its own; [`open_phase!`](@ref) passes the lock of the chain
the phase joins.
"""
Phase(name::AbstractString, kind::PhaseKind, lock::ReentrantLock=ReentrantLock()) =
    Phase(name, kind, 0, time_ns(), nothing, lock)

"""
    isopen(phase::Phase) -> Bool

Whether `phase` is still open. Readable from any task without holding the
chain's lock.
"""
Base.isopen(p::Phase) = @atomic :monotonic p.open

"""
    advance!(phase::Phase, i::Integer)

Record that `phase` has reached position `i`. The position is absolute: `i`
replaces the previous position rather than adding to it, so a duplicated or
dropped report cannot make the position drift.

This is a single atomic store and takes no lock, so it can be called on every
iteration of a sampler.

Throws if a `Determinate` phase would advance past its total, if the position is
negative, or if the phase is closed. On a `Binary` phase, `advance!` does
nothing and never throws.

The closed check is best effort: a report racing with another task closing the
phase, as the run's teardown does, may store one more position after the phase
has closed. That position has passed the same range check as any other, so it is
harmless, but no task can rely on the check to synchronise with the closing one.
"""
advance!(::Phase{Binary}, ::Integer) = nothing

function advance!(p::Phase{Counting}, i::Integer)
    i >= 0 || throw(
        ArgumentError(
            "a position cannot be negative, so the phase \"$(p.name)\" cannot advance to $i",
        ),
    )
    return set_position!(p, i)
end

function advance!(p::Phase{Determinate}, i::Integer)
    total = p.kind.total
    0 <= i <= total || throw(
        ArgumentError(
            "the phase \"$(p.name)\" runs for $total iterations, so it cannot advance to $i",
        ),
    )
    return set_position!(p, i)
end

function set_position!(p::Phase, i::Integer)
    isopen(p) || throw(
        ArgumentError("the phase \"$(p.name)\" is closed, so it cannot advance to $i"),
    )
    @atomic :monotonic p.position = Int(i)
    return nothing
end

"""
    close_phase!(phase::Phase) -> Phase

Record that `phase` is over, stamping the closing time. A closed phase keeps the
position it last reached and cannot be advanced or closed again.
"""
function close_phase!(p::Phase)
    lock(p.lock) do
        isopen(p) || throw(ArgumentError("the phase \"$(p.name)\" has already been closed"))
        close!(p, time_ns())
    end
    return p
end

# The caller holds the phase's lock, which publishes the closing time to a
# snapshot. `open` is atomic because `advance!` reads it without that lock.
function close!(p::Phase, at::UInt64)
    p.closed = at
    @atomic :monotonic p.open = false
    return p
end

"""
    PhaseSnapshot{K<:PhaseKind}

An immutable copy of a phase's state at one instant: an `id`, and the name,
kind, position, opening time and closing time a live [`Phase`](@ref) carries.
Holds no reference back into live state.

Two phases on one chain may share a name, as when a sampler revisits adaptation,
so `id` is what tells them apart.
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
    snapshot(p::Phase) -> PhaseSnapshot

Copy the state of `p` into a `PhaseSnapshot`. The closing time is read while the
chain's lock is held, so a closed phase's snapshot carries its final position.
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
