"""
    ProgressLoggingBackend()

A backend that emits one [ProgressLogging.jl](https://github.com/JuliaLogging/ProgressLogging.jl)
log record per phase, for whichever progress monitor the session has installed
to read them. Needs the ProgressLogging extension loaded: run
`using ProgressLogging` before this backend is selected.

A ProgressLogging record carries only a name and a fraction, so each record's
name states both the chain and the phase.
"""
struct ProgressLoggingBackend end

backend_package(::ProgressLoggingBackend) = "ProgressLogging"
