"""
    ProgressLoggingBackend()

A backend that emits [ProgressLogging.jl](https://github.com/JuliaLogging/ProgressLogging.jl)
records for phase opens, updates, and closes, displayed by the session logger.
Requires `using ProgressLogging`.

Determinate phases report changes of at least half a percentage point and all
transitions to or from 100% observed during refresh. Counting and binary phases
report indeterminate progress on open. Every phase reports its close.
"""
struct ProgressLoggingBackend end

backend_package(::ProgressLoggingBackend) = "ProgressLogging"
