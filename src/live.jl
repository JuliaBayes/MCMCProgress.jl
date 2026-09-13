# Concurrency
#
# A chain is written to by the task running it and read by the task refreshing
# the display, so the two overlap in time. The division of labour is:
#
#   * A phase's `position` is an atomic field. `advance!` stores to it with
#     monotonic (relaxed) ordering and takes no lock, because the value stands
#     for nothing but itself: a reader that sees a slightly stale position draws
#     a slightly stale position, which is the whole of the harm.
#   * Everything structural — which phases a chain has opened, whether a phase is
#     still open and when it closed, and the chain's outcome — is written and
#     read only while the chain's `lock` is held. `Phase.lock` is the lock of the
#     chain that owns the phase, so one lock guards a chain and all its phases.
#   * `Phase.open` is the one piece of structural state that is also readable
#     without the lock, and is atomic for that reason: `advance!` has to reject a
#     closed phase without taking a lock. It carries no other information; the
#     closing time it accompanies is read under the lock.
#
# One task at a time opens, advances and closes the phases of any one chain.
# Other tasks only read, or act after that task has ended.
#
# Two consequences a snapshot relies on:
#
#   * A phase is never seen half-built. It is fully constructed before the lock
#     is taken and appended to the chain while the lock is held, so a reader
#     holding the lock sees either no phase or a complete one.
#   * A phase that a reader sees as closed carries the last position stored
#     before it closed. Releasing the lock publishes every earlier write by the
#     reporting task — the relaxed store of the position included — to whichever
#     task acquires the lock next.

"""
    Phase{K<:PhaseKind}

The live state of one phase on one chain: its name, kind, position, and the times
it opened and closed. `closed` is `nothing` while the phase is still open, and
`open` says the same thing in a form that can be read without the chain's lock.

`Phase` is mutable, so two phases keep separate identities even when every field
matches — this is what lets a chain revisit a phase name (adaptation running a
second time, say) without the two occurrences being confused with one another.
Position is meaningless for a `Binary` phase; it stays at its initial value for
one.

`lock` guards the phase's closure and the chain it belongs to. Every phase a
chain opens shares the chain's lock.
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
[`time_ns`](@ref), a monotonic clock unaffected by wall-clock adjustments. A
phase given no lock gets one of its own; [`openphase!`](@ref) passes the lock of
the chain the phase joins.
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
    Chain

The live state of one chain: its index within the run, the ordered phases it has
opened so far, and its outcome once it has one (`nothing` while still running).

`lock` guards the phases and the outcome. It is held only to open a phase, close
one, set the outcome, or read that state for a snapshot — never while a position
is recorded, so reporting a position on one chain cannot be delayed by work on
another.
"""
mutable struct Chain
    index::Int
    phases::Vector{Phase}
    outcome::Union{Outcome,Nothing}
    lock::ReentrantLock

    function Chain(
        index::Integer,
        phases::AbstractVector{Phase},
        outcome::Union{Outcome,Nothing},
        lock::ReentrantLock=ReentrantLock(),
    )
        index >= 1 || throw(ArgumentError("a chain index must be at least 1, got $index"))
        new(Int(index), collect(Phase, phases), outcome, lock)
    end
end

"""
    Chain(index)

Create a chain at the given index with no phases opened yet.
"""
Chain(index::Integer) = Chain(index, Phase[], nothing)

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
fixed for the life of the run; phases are not — a chain announces each as it
enters it.
"""
Run(label::AbstractString, nchains::Integer) = Run(label, [Chain(i) for i in 1:nchains])
