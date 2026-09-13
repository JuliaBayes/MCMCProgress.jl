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
a fresh `UUID` for every phase currently open, keyed by the phase's own `id`
so that a later `refresh` or `phase_closed` call reports under the same id
that `phase_opened` minted for it.
"""
struct ProgressLoggingHandle
    ids::Dict{UInt,UUID}
end

setup(::ProgressLoggingBackend, ::RunSnapshot) = ProgressLoggingHandle(Dict{UInt,UUID}())

# A determinate phase's fraction of its total, ProgressLogging's `progress`
# value for a known-length phase; a phase with no total (counting or binary)
# has none, which is how ProgressLogging spells indeterminate progress.
_fraction(phase::PhaseSnapshot{Determinate}) =
    phase.kind.total == 0 ? 1.0 : phase.position / phase.kind.total
_fraction(::PhaseSnapshot) = nothing

# The name ProgressLogging shows on a phase's bar. A record has nowhere else
# to say which chain a phase belongs to, so the chain index goes alongside
# the phase's own name.
_barname(chain_index::Integer, phase::PhaseSnapshot) = "chain $chain_index · $(phase.name)"

function phase_opened(
    handle::ProgressLoggingHandle,
    chain_index::Integer,
    phase::PhaseSnapshot,
)
    id = uuid4()
    handle.ids[phase.id] = id
    @logmsg ProgressLevel _barname(chain_index, phase) progress = _fraction(phase) _id = id
    return nothing
end

function phase_closed(
    handle::ProgressLoggingHandle,
    chain_index::Integer,
    phase::PhaseSnapshot,
)
    id = pop!(handle.ids, phase.id)
    @logmsg ProgressLevel _barname(chain_index, phase) progress = "done" _id = id
    return nothing
end

function refresh(handle::ProgressLoggingHandle, snapshot::RunSnapshot)
    for chain in snapshot.chains
        for phase in chain.phases
            phase.closed === nothing || continue
            id = handle.ids[phase.id]
            @logmsg ProgressLevel _barname(chain.index, phase) progress = _fraction(phase) _id =
                id
        end
    end
    return nothing
end

teardown(::ProgressLoggingHandle, ::RunSnapshot) = nothing

end
