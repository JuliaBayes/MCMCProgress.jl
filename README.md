# MCMCProgress

[![Build Status](https://github.com/simonsteiger/MCMCProgress.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/simonsteiger/MCMCProgress.jl/actions/workflows/CI.yml?query=branch%3Amain)

Report live diagnostics while sampling:

```julia
progress(; label="My model", nchains=4, diagnostics=diagnostic_snapshot) do run
    # Run the sampler and report progress as usual.
end
```

`diagnostic_snapshot()` returns one named tuple per chain, for example
`[(draws=2400, divergences=0, depth_hits=0), ...]`. Term shows these values
below its bars; plain text includes them in progress updates and final summaries.

See the [live diagnostics guide](docs/src/diagnostics.md) for details, or
[the Metropolis example](examples/diagnostics.jl) for live acceptance statistics
from a sampler.
