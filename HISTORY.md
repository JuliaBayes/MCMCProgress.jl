# 0.2.0

## Breaking changes

Instead of reporting progress with `PlainTextBackend()`, passing `backend=nothing` now omits all progress reporting.
The same can be achieved by passing `backend=()`.

## Other changes

ProgressLogging skips determinate updates smaller than half a percentage point to
reduce log traffic. It still reports when a phase opens, closes, or transitions
to or from 100%.

# 0.1.0

Initial release with a common interface for reporting MCMC progress across chains
and phases, and plain text, Term.jl, and ProgressLogging.jl display backends.
