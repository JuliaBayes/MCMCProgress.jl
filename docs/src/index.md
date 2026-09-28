# MCMCProgress.jl

MCMCProgress is a package for monitoring the progress of MCMC samplers.
It provides a backend-agnostic interface which sampling packages can use to register progress updates, as well as several backends which render those updates in different ways:

- A plain text backend, which simply prints updates (useful when running non-interactively, e.g. on a cluster);
- A [Term.jl](https://github.com/FedeClaudi/Term.jl) backend, which provides beautiful progress updates in terminals;
- A [ProgressLogging.jl](https://github.com/JuliaLogging/ProgressLogging.jl) backend, which is less fancy than the Term.jl backend, but is better tested across different platforms.
