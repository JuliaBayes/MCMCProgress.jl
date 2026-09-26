# API reference

## Runs

As described in the main documentation, a `Run` object is the top-level object that tracks the progress of one MCMC run.

```@docs
MCMCProgress.Run
MCMCProgress.Outcome
```

## Chains

Each `Run` contains progress logs for one or more MCMC chains.
The progress for each chain is tracked by a `Chain` object.

```@docs
MCMCProgress.chains
MCMCProgress.num_chains
MCMCProgress.Chain
MCMCProgress.chain
```

## Phases

MCMCProgress currently exposes the following phase types:

```@docs
MCMCProgress.Phase
MCMCProgress.PhaseKind
MCMCProgress.Binary
MCMCProgress.Counting
MCMCProgress.Determinate
```

Phases can be manipulated and queried with the following functions:

```@docs
MCMCProgress.openphase!
MCMCProgress.advance!
MCMCProgress.closephase!
MCMCProgress.phase_opened
MCMCProgress.phase_closed
```

## Snapshots

The `Run`, `Chain`, and `Phase` objects are mutable.
At regular intervals, MCMCProgress takes a _snapshot_ of the current state of the run, and stores it in a `RunSnapshot`, `ChainSnapshot`, or `PhaseSnapshot` object, which is then sent to the backend.

```@docs
MCMCProgress.RunSnapshot
MCMCProgress.ChainSnapshot
MCMCProgress.PhaseSnapshot
```

## Backends

```@docs
MCMCProgress.ProgressLoggingBackend
MCMCProgress.PlainTextBackend
MCMCProgress.TermBackend
```

```@docs
MCMCProgress.setbackend!
MCMCProgress.backend_package
MCMCProgress.refresh
MCMCProgress.progress
MCMCProgress.setup
MCMCProgress.teardown
```
