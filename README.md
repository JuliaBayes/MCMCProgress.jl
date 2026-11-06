# MCMCProgress.jl

[![Stable docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliabayes.org/MCMCProgress.jl/)
[![Build Status](https://github.com/simonsteiger/MCMCProgress.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/simonsteiger/MCMCProgress.jl/actions/workflows/CI.yml?query=branch%3Amain)

This package provides a common interface to monitor the progress of MCMC samplers.

It exports a backend-agnostic interface that enables sampling packages to report progress.
MCMCProgress.jl also features several backends to render those reports in different ways, depending on your needs or preferences.

## Backends

- `PlainTextBackend` prints only plain text. This is useful when running non-interactively, for example on a cluster (or if you just feel very vanilla).
- `TermBackend` creates fancy progress bars in the terminal with [Term.jl](https://github.com/FedeClaudi/Term.jl).
- `ProgressLoggingBackend` uses [ProgressLogging.jl](https://github.com/JuliaLogging/ProgressLogging.jl). It is better tested across different platforms than `TermBackend` but not quite as fancy.

To use `TermBackend` or `ProgressLoggingBackend`, you will have to load Term.jl or ProgressLogging.jl, respectively.

## Example gallery

From a checkout, install the example dependencies and run the gallery:

```sh
julia --project=examples -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=examples examples/gallery.jl --help
```

The explicit `Pkg.develop` also selects the checkout on Julia 1.10, which does not support `[sources]`.
