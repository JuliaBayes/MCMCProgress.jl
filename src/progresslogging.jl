"""
    ProgressLoggingBackend()

A backend that emits one [ProgressLogging.jl](https://github.com/JuliaLogging/ProgressLogging.jl)
log record per phase, displayed by whatever logger the session has installed.
Requires `using ProgressLogging`.

A record has only a name and a fraction, so the name gives both the chain index
and the phase name.
"""
struct ProgressLoggingBackend end

backend_package(::ProgressLoggingBackend) = "ProgressLogging"
