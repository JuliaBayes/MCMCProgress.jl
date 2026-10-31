# [Live diagnostics](@id live-diagnostics)

Pass a zero-argument function as `diagnostics` to [`progress`](@ref MCMCProgress.progress)
to display sampler statistics alongside progress. The function returns one named
tuple per chain, in a tuple or vector. Field names label the displayed values:

```julia
diagnostic_snapshot() = (
    (draws=2400, divergences=0, acceptance=0.81),
    (draws=2300, divergences=2, acceptance=0.76),
)
```

Term shows these values below its bars. Plain text includes them in progress
updates and final summaries. The chain's diagnostics are not shown when its
named tuple is empty. Custom backends read the values from `snapshot.diagnostics`.

## Collecting values safely

The sampler calculates the statistics. Its chains can update counters while the
display reads them, so the diagnostics function must use the same synchronization
as those updates. For example, read each chain's counters and construct its named
tuple while holding the lock that protects those counters.

The function runs on the refresh task during sampling and on the calling task
for the final display, after the refresh task stops. It must be safe to call from
either task. MCMCProgress calls it outside its own progress locks, so the function
can acquire the sampler's locks.

## Keeping snapshots stable

All backends share each diagnostics snapshot. Its values must stay unchanged
while the backends read them. Prefer scalar summaries, or copy mutable field
values before returning them.

MCMCProgress copies a returned vector in chain order, so replacing its rows in a
later callback does not change an earlier display snapshot. This copy is shallow:
objects inside the named tuples are still shared. The sampler must not modify the
vector concurrently while MCMCProgress copies it.

## Interpreting the values

Keep warmup and sampling statistics separate. For example, reset acceptance
counters when sampling begins if the displayed rate should exclude warmup.
Include the draw count used to calculate a rate, such as
`(draws=2400, acceptance=0.81)`, when it differs from the progress count.

Progress and diagnostics are not read together. Consequently, progress and
diagnostics may reflect slightly different draws in any given refresh.

## Handling callback failures

If the diagnostics function throws during a refresh, the display stops refreshing
but sampling continues. The error is logged immediately and reported to the caller
when `progress` ends, following the same failure rules as a backend.

If the final diagnostics call fails, MCMCProgress still cleans up the displays
using a progress snapshot without diagnostics. If sampling itself throws, its
original exception is preserved and display failures are logged.

The [Metropolis example](https://github.com/JuliaBayes/MCMCProgress.jl/blob/main/examples/diagnostics.jl)
shows a sampler with per-chain locks and live acceptance statistics.
