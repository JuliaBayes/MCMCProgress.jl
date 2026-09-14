using Printf: @sprintf

"""
    PlainTextHandle

The mutable state behind [`PlainTextBackend`](@ref): the destination `io`, the
clock for timing an open phase, the run's label and chain count, and the last
progress key written for each chain index.
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

# How coarse the output is: `refresh` writes a line for a chain only once the
# phase's bucket has moved, which holds a ten-thousand-step phase to a few dozen
# lines. A determinate phase's bucket is its percentage rounded to a multiple of
# five; a counting phase, having no total, buckets its position by
# `_COUNTING_STEP`, matching CmdStan's default `refresh` of 100 iterations; a
# binary phase has no position, so its bucket never moves and nothing further is
# written for it until the phase closes.
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

# An open phase is timed against `handle.now`; a closed phase's `opened` and
# `closed` fields fix its elapsed time without consulting the clock.
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
