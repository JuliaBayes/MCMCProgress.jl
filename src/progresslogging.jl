"""
    ProgressLoggingBackend() <: AbstractBackend

A backend that emits
[ProgressLogging.jl](https://github.com/JuliaLogging/ProgressLogging.jl) records for phase
opens, progress updates, and closes. Requires `using ProgressLogging`.
"""
struct ProgressLoggingBackend <: AbstractBackend end

backend_package(::ProgressLoggingBackend) = "ProgressLogging"
