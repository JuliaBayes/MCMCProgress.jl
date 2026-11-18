# Unreleased

ProgressLogging skips unchanged updates and reports determinate changes of at
least half a percentage point. It still reports phase opens, closes, and
transitions to or from 100% seen during refresh.

# 0.1.0

Initial release with a common interface for reporting MCMC progress across chains
and phases, and plain text, Term.jl, and ProgressLogging.jl display backends.
