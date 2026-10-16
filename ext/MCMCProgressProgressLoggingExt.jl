module MCMCProgressProgressLoggingExt

using MCMCProgress:
    MCMCProgress, ProgressLoggingBackend, PhaseSnapshot, RunSnapshot, Determinate
import MCMCProgress: setup, phase_opened, phase_closed, refresh, teardown
using ProgressLogging: ProgressLevel
using Logging: @logmsg
using UUIDs: UUID, uuid4

"""
    ProgressLoggingHandle

The mutable state behind [`ProgressLoggingBackend`](@ref MCMCProgress.ProgressLoggingBackend):
maps each open phase's `id` to the `UUID` that all of that phase's log records
use.
"""
struct ProgressLoggingHandle
    n_chains::Int
    ids::Dict{UInt,UUID}
end

setup(::ProgressLoggingBackend, snapshot::RunSnapshot) =
    ProgressLoggingHandle(length(snapshot.chains), Dict{UInt,UUID}())

# ProgressLogging's `progress` value: a determinate phase's fraction of its
# total, and `nothing` for a counting or binary phase, which is how
# ProgressLogging spells indeterminate progress.
_fraction(phase::PhaseSnapshot{Determinate}) =
    phase.kind.total == 0 ? 1.0 : phase.position / phase.kind.total
_fraction(::PhaseSnapshot) = nothing

# A record has no field for the chain, so its name carries the chain index.
_bar_name(handle, chain_index, phase) =
    "chain $chain_index/$(handle.n_chains): $(phase.name)"

function phase_opened(
    handle::ProgressLoggingHandle,
    chain_index::Integer,
    phase::PhaseSnapshot,
)
    id = uuid4()
    handle.ids[phase.id] = id
    @logmsg ProgressLevel _bar_name(handle, chain_index, phase) progress =
        _fraction(phase) _id = id
    return nothing
end

function phase_closed(
    handle::ProgressLoggingHandle,
    chain_index::Integer,
    phase::PhaseSnapshot,
)
    id = pop!(handle.ids, phase.id)
    @logmsg ProgressLevel _bar_name(handle, chain_index, phase) progress = "done" _id = id
    return nothing
end

function refresh(handle::ProgressLoggingHandle, snapshot::RunSnapshot)
    for chain in snapshot.chains
        for phase in chain.phases
            phase.closed === nothing || continue
            id = handle.ids[phase.id]
            @logmsg ProgressLevel _bar_name(handle, chain.index, phase) progress =
                _fraction(phase) _id = id
        end
    end
    return nothing
end

teardown(::ProgressLoggingHandle, ::RunSnapshot) = nothing

end
