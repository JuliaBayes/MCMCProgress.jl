module MCMCProgress

export PhaseKind, Determinate, Counting, Binary
export Outcome, finished, failed, interrupted
export RunSnapshot, ChainSnapshot, PhaseSnapshot
export progress, chain, openphase!, advance!, closephase!
export setup, phase_opened, phase_closed, refresh, teardown
export setbackend!, PlainTextBackend, backend_package
export ProgressLoggingBackend
export TermBackend

include("phase_kinds.jl")
include("outcome.jl")
include("live.jl")
include("report.jl")
include("snapshot.jl")
include("show.jl")
include("backends.jl")
include("plaintext.jl")
include("progresslogging.jl")
include("term.jl")
include("scope.jl")
include("recording_backend.jl")

end
