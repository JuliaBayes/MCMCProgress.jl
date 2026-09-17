using Printf: @sprintf

"""
    PlainTextHandle

The mutable state behind [`PlainTextBackend`](@ref). `last_written` maps a chain
index to the `(phase id, bucket)` of the last line written for that chain.
"""
mutable struct PlainTextHandle{F}
    io::IO
    now::F
    label::String
    n_chains::Int
    last_written::Dict{Int,Tuple{UInt,Int}}

    PlainTextHandle{F}(io, now, label, n_chains, last_written) where {F} =
        new{F}(io, now, label, n_chains, last_written)
end

PlainTextHandle(io::IO, now::F, label::AbstractString, n_chains::Integer) where {F} =
    PlainTextHandle{F}(io, now, String(label), Int(n_chains), Dict{Int,Tuple{UInt,Int}}())

# `refresh` writes a chain's line only when its phase's bucket changes, which
# limits a ten-thousand-step phase to a few dozen lines. A determinate phase's
# bucket is its percentage divided by five, a counting phase's is its position
# divided by `_COUNTING_STEP`, and a binary phase's never changes, so it gets no
# lines between opening and closing.
const _COUNTING_STEP = 100

_bucket(::PhaseSnapshot{Binary}) = 0
_bucket(phase::PhaseSnapshot{Counting}) = phase.position ÷ _COUNTING_STEP
function _bucket(phase::PhaseSnapshot{Determinate})
    return _percent(phase) ÷ 5
end

function _percent(phase::PhaseSnapshot{Determinate})
    total = phase.kind.total
    total == 0 && return 100
    return round(Int, 100 * phase.position / total)
end

_phase_text(phase::PhaseSnapshot{Determinate}) = string(
    phase.name,
    " ",
    phase.position,
    "/",
    phase.kind.total,
    " (",
    _percent(phase),
    "%)",
)
_phase_text(phase::PhaseSnapshot{Counting}) = string(phase.name, " ", phase.position)
_phase_text(phase::PhaseSnapshot{Binary}) = phase.name

# Only an open phase reads `handle.now`; a closed phase is timed from its own
# timestamps.
function _elapsed_seconds(handle::PlainTextHandle, phase::PhaseSnapshot)
    finish = phase.closed === nothing ? handle.now() : phase.closed
    return (finish - phase.opened) / 1e9
end

function _chain_elapsed_seconds(handle::PlainTextHandle, chain::ChainSnapshot)
    isempty(chain.phases) && return nothing
    started = first(chain.phases).opened
    last_phase = last(chain.phases)
    finish = last_phase.closed === nothing ? handle.now() : last_phase.closed
    return (finish - started) / 1e9
end

function _write_phase_line!(
    handle::PlainTextHandle,
    chain_index::Integer,
    phase::PhaseSnapshot,
)
    line = @sprintf(
        "[%s] chain %d/%d · %s · %.1fs",
        handle.label,
        chain_index,
        handle.n_chains,
        _phase_text(phase),
        _elapsed_seconds(handle, phase),
    )
    println(handle.io, line)
    handle.last_written[chain_index] = (phase.id, _bucket(phase))
    return nothing
end

function setup(backend::PlainTextBackend, snapshot::RunSnapshot)
    return PlainTextHandle(backend.io, backend.now, snapshot.label, length(snapshot.chains))
end

function phase_opened(handle::PlainTextHandle, chain_index::Integer, phase::PhaseSnapshot)
    _write_phase_line!(handle, chain_index, phase)
    return nothing
end

function phase_closed(handle::PlainTextHandle, chain_index::Integer, phase::PhaseSnapshot)
    _write_phase_line!(handle, chain_index, phase)
    return nothing
end

function refresh(handle::PlainTextHandle, snapshot::RunSnapshot)
    for chain in snapshot.chains
        chain.outcome === nothing || continue
        isempty(chain.phases) && continue
        phase = last(chain.phases)
        phase.closed === nothing || continue
        key = (phase.id, _bucket(phase))
        get(handle.last_written, chain.index, nothing) == key && continue
        _write_phase_line!(handle, chain.index, phase)
    end
    return nothing
end

function teardown(handle::PlainTextHandle, snapshot::RunSnapshot)
    for chain in snapshot.chains
        chain.outcome === nothing && continue
        elapsed = _chain_elapsed_seconds(handle, chain)
        line = if elapsed === nothing
            @sprintf(
                "[%s] chain %d/%d · %s",
                handle.label,
                chain.index,
                handle.n_chains,
                chain.outcome
            )
        else
            @sprintf(
                "[%s] chain %d/%d · %s · %.1fs",
                handle.label,
                chain.index,
                handle.n_chains,
                chain.outcome,
                elapsed,
            )
        end
        println(handle.io, line)
    end
    return nothing
end
