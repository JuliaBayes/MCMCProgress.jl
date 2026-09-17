"""
    setup(backend, snapshot::RunSnapshot) -> handle

Turn `backend` into a handle holding whatever mutable state its display
needs. Called once, as the run starts; `snapshot` is the run's initial state,
with every chain present and no phase open yet.

Every other function in the interface is called with what `setup` returns
here, never with `backend` itself.

# The interface

A backend implements up to five functions, called at these points:

| Function                              | Called                      |
|:-------------------------------------- |:---------------------------|
| [`setup`](@ref)                        | once, as the run starts     |
| [`phase_opened`](@ref)                 | when a chain enters a phase |
| [`phase_closed`](@ref)                 | when a chain leaves a phase |
| [`refresh`](@ref)                      | on a fixed clock            |
| [`teardown`](@ref)                     | once, as the run ends       |

`phase_opened` and `phase_closed` default to doing nothing, so the smallest
possible backend implements only `setup`, `refresh`, and `teardown`.

A backend must not throw when a chain opens a phase at any point during the run,
or when a run ends as `failed` or `interrupted`.
"""
function setup end

"""
    phase_opened(handle, chain_index::Integer, phase::PhaseSnapshot)

Called when the chain at `chain_index` opens `phase`. The default does
nothing.

`phase` is a snapshot rather than a reference into live state. Two phases on one
chain may share a name, as when a sampler runs adaptation a second time, so a
backend tells them apart by `phase.id`.
"""
phase_opened(handle, chain_index::Integer, phase::PhaseSnapshot) = nothing

"""
    phase_closed(handle, chain_index::Integer, phase::PhaseSnapshot)

Called when the chain at `chain_index` leaves `phase`. The default does
nothing.
"""
phase_closed(handle, chain_index::Integer, phase::PhaseSnapshot) = nothing

"""
    refresh(handle, snapshot::RunSnapshot)

Called on a fixed clock, independent of how fast chains report, so the
active backend can redraw from `snapshot`, the run's current state.
"""
function refresh end

"""
    teardown(handle, snapshot::RunSnapshot)

Called once, as the run ends, so the backend can release whatever `setup`
acquired. `snapshot` is the run's final state, including every chain's
outcome.
"""
function teardown end

"""
    backend_package(backend) -> Union{String,Nothing}

The name of the package whose extension must be loaded before `backend` can
be used, or `nothing` if `backend` needs no extension. A backend supplied by a
package extension overrides this method, so selecting it before its package is
loaded throws an error naming the package rather than a `MethodError` from
inside [`setup`](@ref).
"""
backend_package(::Any) = nothing

function _check_backend_loaded(backend)
    hasmethod(setup, Tuple{typeof(backend),RunSnapshot}) && return backend
    pkg = backend_package(backend)
    pkg === nothing && return backend
    throw(
        ArgumentError(
            "the $(typeof(backend)) backend needs its extension loaded: run `using $pkg` first",
        ),
    )
end

"""
    PlainTextBackend(io::IO=stdout; now=time_ns)

A backend that writes lines of plain text to `io`. It is what
[`resolve_backend`](@ref) returns when no other backend is selected, and needs
no package extension.

`now` times a phase that is still open: called with no arguments, it must
return a `UInt64` count of nanoseconds, as `time_ns` does. It is not called for
a closed phase.
"""
struct PlainTextBackend{F}
    io::IO
    now::F

    PlainTextBackend{F}(io, now) where {F} = new{F}(io, now)
end
PlainTextBackend(io::IO=stdout; now=time_ns) = PlainTextBackend{typeof(now)}(io, now)

const _DEFAULT_BACKEND = Ref{Any}(nothing)

"""
    set_backend!(backend)

Set the process-wide default backend: what [`resolve_backend`](@ref) returns
for a run started without an explicit `backend` argument. Can be called from
`startup.jl`. Throws if `backend` needs a package extension that is not loaded.
"""
function set_backend!(backend)
    _check_backend_loaded(backend)
    _DEFAULT_BACKEND[] = backend
    return backend
end

"""
    resolve_backend(explicit=nothing)

The backend a run should use, in order of precedence: `explicit` if it is
not `nothing`, otherwise the process-wide default set by
[`set_backend!`](@ref), otherwise [`PlainTextBackend`](@ref). Throws if the
resolved backend needs a package extension that is not loaded.

Loading a package extension does not change this result: a backend becomes
active only once passed here or given to `set_backend!`.
"""
function resolve_backend(explicit=nothing)
    backend = if explicit !== nothing
        explicit
    elseif _DEFAULT_BACKEND[] !== nothing
        _DEFAULT_BACKEND[]
    else
        PlainTextBackend()
    end
    _check_backend_loaded(backend)
    return backend
end
