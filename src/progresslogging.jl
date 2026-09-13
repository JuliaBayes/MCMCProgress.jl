"""
    ProgressLoggingBackend()

The backend that emits one [ProgressLogging.jl](https://github.com/JuliaLogging/ProgressLogging.jl)
log record per phase, for whichever progress monitor the session has
installed to read them — a terminal progress bar, or nothing at all. Needs
the ProgressLogging extension loaded: run `using ProgressLogging` before this
backend is selected.

A ProgressLogging record carries only a name and a fraction, so each record's
name states both the chain the phase belongs to and the phase's own name.
"""
struct ProgressLoggingBackend end

backend_package(::ProgressLoggingBackend) = "ProgressLogging"
