module MCMCProgressProgressLoggingExt

using MCMCProgress:
    MCMCProgress, ProgressLoggingBackend, PhaseSnapshot, RunSnapshot, Determinate
import MCMCProgress: setup, phase_opened, phase_closed, refresh, teardown
using ProgressLogging: ProgressLevel
using Logging: @logmsg
using UUIDs: UUID, uuid4

MCMCProgress.is_loaded(::ProgressLoggingBackend) = true

mutable struct LoggedPhase
    const id::UUID
    const name::String
    position::Int
end

struct ProgressLoggingHandle
    n_chains::Int
    phases::Dict{UInt,LoggedPhase}
end

setup(::ProgressLoggingBackend, snapshot::RunSnapshot) =
    ProgressLoggingHandle(length(snapshot.chains), Dict{UInt,LoggedPhase}())

# ProgressLogging's `progress` value: a determinate phase's fraction of its
# total, and `nothing` for a counting or binary phase, which is how
# ProgressLogging spells indeterminate progress.
_fraction(phase::PhaseSnapshot{Determinate}) =
    phase.kind.total == 0 ? 1.0 : phase.position / phase.kind.total
_fraction(::PhaseSnapshot) = nothing

const UPDATES_PER_TOTAL = 200

function log_position!(state::LoggedPhase, phase::PhaseSnapshot)
    @logmsg ProgressLevel state.name progress = _fraction(phase) _id = state.id
    state.position = phase.position
    return nothing
end

function phase_opened(
    handle::ProgressLoggingHandle,
    chain_index::Integer,
    phase::PhaseSnapshot,
)
    state = get!(handle.phases, phase.id) do
        name = "chain $chain_index/$(handle.n_chains): $(phase.name)"
        LoggedPhase(uuid4(), name, phase.position)
    end
    return log_position!(state, phase)
end

function phase_closed(handle::ProgressLoggingHandle, ::Integer, phase::PhaseSnapshot)
    state = pop!(handle.phases, phase.id, nothing)
    state === nothing && return nothing
    @logmsg ProgressLevel state.name progress = "done" _id = state.id
    return nothing
end

function refresh(handle::ProgressLoggingHandle, snapshot::RunSnapshot)
    for chain in snapshot.chains
        # A chain can only have its latest phase open.
        isempty(chain.phases) && continue
        phase = last(chain.phases)
        phase.closed === nothing || continue
        phase.kind isa Determinate || continue
        state = handle.phases[phase.id]
        position = phase.position
        previous = state.position
        position == previous && continue
        total = phase.kind.total
        if max(position, previous) < total &&
           abs(position - previous) < cld(total, UPDATES_PER_TOTAL)
            continue
        end
        log_position!(state, phase)
    end
    return nothing
end

function teardown(handle::ProgressLoggingHandle, snapshot::RunSnapshot)
    isempty(handle.phases) && return nothing
    # A sibling callback can prevent the final close announcement.
    for chain in snapshot.chains, phase in chain.phases
        phase_closed(handle, chain.index, phase)
    end
    return nothing
end

end
