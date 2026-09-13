"""
    setup(backend, snapshot::RunSnapshot) -> handle

Turn `backend` into a handle holding whatever mutable state its display
needs. Called once, as the run starts; `snapshot` is the run's initial
state — every chain present, no phase open yet.

Every other function in the interface is called with whatever `setup`
returns here, never with `backend` itself.

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

Every backend must tolerate a chain opening a phase it has not announced
before at any point during the run, and must tolerate a run whose outcome
turns out to be `failed` or `interrupted` rather than `finished` — neither is
a condition a backend may raise an error over or otherwise refuse.
"""
function setup end

"""
    phase_opened(handle, chain_index::Integer, phase::PhaseSnapshot)

Called when the chain at `chain_index` opens `phase`. The default does
nothing, so a backend with no per-phase apparatus to create need not
implement this.

`phase` is a snapshot rather than a reference into live state: its `id`
field is what lets a backend tell apart two phases that share a name on one
chain (a sampler that runs adaptation a second time, say) instead of
confusing them by name.
"""
phase_opened(handle, chain_index::Integer, phase::PhaseSnapshot) = nothing

"""
    phase_closed(handle, chain_index::Integer, phase::PhaseSnapshot)

Called when the chain at `chain_index` leaves `phase`. The default does
nothing, so a backend with no per-phase apparatus to complete need not
implement this.
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
be used, or `nothing` if `backend` needs no extension. A backend type
supplied by a package extension overrides this method so that selecting it
before its package is loaded produces a clear error naming the package,
rather than a `MethodError` raised from inside [`setup`](@ref).
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

The backend [`resolve_backend`](@ref) falls back to when nothing else is
selected. Needs nothing but `io` to write to, and no package extension.

`now` times a phase that is still open: called with no arguments, it must
return a `UInt64` count of nanoseconds, the convention `time_ns` follows.
Rendering a closed phase never calls it, since a closed phase's own opening
and closing times already fix its elapsed time. Tests pass a fixed clock here
to make elapsed time deterministic.
"""
struct PlainTextBackend{F}
    io::IO
    now::F

    PlainTextBackend{F}(io, now) where {F} = new{F}(io, now)
end
PlainTextBackend(io::IO=stdout; now=time_ns) = PlainTextBackend{typeof(now)}(io, now)

const _DEFAULT_BACKEND = Ref{Any}(nothing)

"""
    setbackend!(backend)

Set the process-wide default backend: what [`resolve_backend`](@ref) returns
for a run started without an explicit `backend` argument. Meant for a
`startup.jl` that configures a preferred backend once and forgets about it.
Throws if `backend` needs a package extension that is not loaded.
"""
function setbackend!(backend)
    _check_backend_loaded(backend)
    _DEFAULT_BACKEND[] = backend
    return backend
end

"""
    resolve_backend(explicit=nothing)

The backend a run should use, in order of precedence: `explicit` if it is
not `nothing`, otherwise the process-wide default set by
[`setbackend!`](@ref), otherwise [`PlainTextBackend`](@ref). Throws if the
resolved backend needs a package extension that is not loaded.

Loading a package extension never changes this result by itself — a backend
only becomes active once passed here or given to `setbackend!`. A session
with both the Term and ProgressLogging extensions loaded has no default
winner between them.
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
