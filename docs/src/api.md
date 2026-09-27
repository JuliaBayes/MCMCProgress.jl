# API reference

## Runs

As described in the main documentation, a `RunProgress` object is the top-level object that tracks the progress of one MCMC run.

```@docs
MCMCProgress.RunProgress
MCMCProgress.progress
```

## Chains

Each `RunProgress` contains progress logs for one or more MCMC chains.
The progress for each chain is tracked by a `ChainProgress` object.

```@docs
MCMCProgress.chains
MCMCProgress.num_chains
MCMCProgress.ChainProgress
MCMCProgress.chain_at
```

## Phases

Each `ChainProgress` object further contains zero or more `Phase`s.
MCMCProgress currently exposes the following phase types:

```@docs
MCMCProgress.Phase
MCMCProgress.Binary
MCMCProgress.Counting
MCMCProgress.Determinate
```

Phases can be manipulated and queried with the following functions:

```@docs
MCMCProgress.open_phase!
MCMCProgress.advance!
MCMCProgress.close_phase!
```

## Backends

```@docs
MCMCProgress.ProgressLoggingBackend
MCMCProgress.PlainTextBackend
MCMCProgress.TermBackend
```
