# MCMCProgress

[![Build Status](https://github.com/simonsteiger/MCMCProgress.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/simonsteiger/MCMCProgress.jl/actions/workflows/CI.yml?query=branch%3Amain)

Supply live diagnostics without a diagnostics dependency:

```julia
progress(; label="My model", nchains=4, diagnostics=diagnostic_snapshot) do run
    # Run the sampler and report progress as usual.
end
```

`diagnostic_snapshot()` returns one named tuple per chain, for example
`[(draws=2400, divergences=0, depth_hits=0), ...]`. The sampler owns the
statistics and synchronization. Return an empty named tuple for a chain with
no diagnostics, and keep warmup and sampling statistics separate.

The display reads these summaries on its refresh task and once at the end.
Term shows them below its bars; plain text adds them to periodic and final
lines, preserving its existing output rate. Custom backends receive them in
`snapshot.diagnostics`. Returned values must remain unchanged after return.

[The Metropolis example](examples/diagnostics.jl) supplies live acceptance
statistics using only the standard library.
