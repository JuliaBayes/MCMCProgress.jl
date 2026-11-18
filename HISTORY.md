# Unreleased

ProgressLogging skips unchanged updates and limits intermediate determinate updates
to half-percentage-point changes. It still reports phase opens and closes.

# 0.1.0

Initial release with a common interface for reporting MCMC progress across chains
and phases, and plain text, Term.jl, and ProgressLogging.jl display backends.
