module MCMCProgress

export PhaseKind, Determinate, Counting, Binary
export Outcome, finished, failed, interrupted
export RunSnapshot, ChainSnapshot, PhaseSnapshot
export progress, chain, open_phase!, advance!, close_phase!
export setup, phase_opened, phase_closed, refresh, teardown
export set_backend!, PlainTextBackend, backend_package
export ProgressLoggingBackend
export TermBackend

include("phase_kinds.jl")
include("outcome.jl")
include("phase.jl")
include("chain.jl")
include("run.jl")
include("backends.jl")
include("plaintext.jl")
include("progresslogging.jl")
include("term.jl")
include("scope.jl")
include("recording_backend.jl")

end
