# MCMCProgress.jl

MCMCProgress is a package for monitoring the progress of MCMC samplers.
It provides a backend-agnostic interface which sampling packages can use to register progress updates, as well as several backends which render those updates in different ways:

- A plain text backend, which simply prints updates (useful when running non-interactively, e.g. on a cluster);
- A [Term.jl](https://github.com/FedeClaudi/Term.jl) backend, which provides beautiful progress updates in terminals;
- A [ProgressLogging.jl](https://github.com/JuliaLogging/ProgressLogging.jl) backend, which is less fancy than the Term.jl backend, but is better tested across different platforms.

## Choosing a backend

You can pick between the backends listed above with the `backend` keyword.

- If you omit `backend` or pass `backend=nothing`, the default is `PlainTextBackend()`. You can change it for the current Julia process with `MCMCProgress.set_backend!`.
- Set `backend=()` or `backend=nothing` to run without a display. The sampler can still report progress.
- Use a tuple to display progress in several ways at once. For example, `backend=(PlainTextBackend(), ProgressLoggingBackend())` prints plain text and sends progress logs.

For `TermBackend()` and `ProgressLoggingBackend()`, you need to load `Term` and `ProgressLogging` first, respectively.
