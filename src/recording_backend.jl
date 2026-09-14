"""
    RecordingBackend()

A backend that renders nothing and records every call the interface makes to
it, in order, in `calls`: `setup`, `phase_opened`, `phase_closed`, `refresh`
and `teardown`. `setup` returns the `RecordingBackend` itself as the handle,
so `calls` is reachable both before and after a run.

Each entry of `calls` is one of:

    (:setup, snapshot)
    (:phase_opened, chain_index, phase)
    (:phase_closed, chain_index, phase)
    (:refresh, snapshot)
    (:teardown, snapshot)
"""
mutable struct RecordingBackend
    calls::Vector{Any}
end
RecordingBackend() = RecordingBackend(Any[])

function setup(backend::RecordingBackend, snapshot::RunSnapshot)
    push!(backend.calls, (:setup, snapshot))
    return backend
end

function phase_opened(handle::RecordingBackend, chain_index::Integer, phase::PhaseSnapshot)
    push!(handle.calls, (:phase_opened, chain_index, phase))
    return nothing
end

function phase_closed(handle::RecordingBackend, chain_index::Integer, phase::PhaseSnapshot)
    push!(handle.calls, (:phase_closed, chain_index, phase))
    return nothing
end

function refresh(handle::RecordingBackend, snapshot::RunSnapshot)
    push!(handle.calls, (:refresh, snapshot))
    return nothing
end

function teardown(handle::RecordingBackend, snapshot::RunSnapshot)
    push!(handle.calls, (:teardown, snapshot))
    return nothing
end
