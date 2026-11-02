# [Live diagnostics](@id live-diagnostics)

Pass a zero-argument `diagnostics` function to [`progress`](@ref MCMCProgress.progress).
Return one named tuple per chain, in a tuple or vector. Fields label the displayed values:

```julia
diagnostic_snapshot() = (
    (draws=2400, divergences=0, acceptance=0.81),
    (draws=2300, divergences=2, acceptance=0.76),
)
```

Term shows the values below its bars; plain text includes them in updates and final
summaries. An empty named tuple hides that chain's diagnostics. Custom backends read
`snapshot.diagnostics`.

## Collecting values safely

Read statistics with the sampler's synchronization, such as its counter locks.
The function runs on the refresh task during sampling
and on the calling task for the final display, after refresh stops. It must support
both tasks. MCMCProgress holds no progress locks while calling it.

## Keeping snapshots stable

All backends share each snapshot. Vectors are copied in chain order, so later row
replacement cannot change an earlier snapshot. The copy is shallow: keep field
values unchanged while backends read them, or copy mutable fields before returning.
Do not modify the vector while MCMCProgress copies it.

## Interpreting the values

Reset acceptance counters after warmup if the rate should exclude warmup. Include
the draw count used for a rate, as in `(draws=2400, acceptance=0.81)`, when it differs
from the progress count.

Progress and diagnostics are not read together. Consequently, progress and
diagnostics may reflect slightly different draws in any given refresh.

## Handling callback failures

If the function throws during refresh, the display stops but sampling continues.
The error is logged immediately and rethrown when `progress` ends. A failed final
call still cleans up displays with a progress snapshot without diagnostics. If
sampling throws, its original exception takes precedence and display errors are logged.

The [Metropolis example](https://github.com/JuliaBayes/MCMCProgress.jl/blob/main/examples/diagnostics.jl)
shows a sampler with per-chain locks and live acceptance statistics.
