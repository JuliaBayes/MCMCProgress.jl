module MCMCProgressTermExt

using MCMCProgress: MCMCProgress, TermBackend, PhaseSnapshot, RunSnapshot, Determinate
import MCMCProgress: setup, phase_opened, phase_closed, refresh, teardown
using Term.Progress:
    ProgressBar,
    ProgressJob,
    addjob!,
    removejob!,
    start!,
    stop!,
    update!,
    render,
    DescriptionColumn,
    SeparatorColumn,
    ProgressColumn,
    CompletedColumn,
    PercentageColumn,
    ETAColumn

"""
    _DEFAULT_COLUMNS

The columns [`TermBackend`](@ref MCMCProgress.TermBackend) builds each phase's
bar from when given no explicit column configuration: a description, the bar
itself, the position and percentage for a determinate phase, and an estimate
of the time remaining. It carries no column for elapsed time — with several
chains each showing a phase, an elapsed-time column alongside everything else
leaves too little width to read.

A counting or binary phase has no total to draw a bar or estimate a remaining
time from. `ProgressJob.start!` removes `ProgressColumn` and adds Term's own
spinner column for such a phase, and `PercentageColumn`/`ETAColumn` render
blank once a job's `N` is `nothing`, all on Term's own side — so this one list
serves every phase kind without a separate list for phases with no total.
"""
const _DEFAULT_COLUMNS = DataType[
    DescriptionColumn,
    SeparatorColumn,
    ProgressColumn,
    SeparatorColumn,
    CompletedColumn,
    PercentageColumn,
    SeparatorColumn,
    ETAColumn,
]

_columns(::TermBackend{Nothing}) = copy(_DEFAULT_COLUMNS)
_columns(backend::TermBackend) = backend.columns

# A determinate phase supplies Term's job total; a counting or binary phase
# withholds it, which is what makes `ProgressJob.start!` attach a spinner.
_total(phase::PhaseSnapshot{Determinate}) = phase.kind.total
_total(::PhaseSnapshot) = nothing

# A job has nowhere else to say which chain its phase belongs to, so the
# chain index goes alongside the phase's own name.
_description(
    chain_index::Integer,
    phase::PhaseSnapshot,
) = "chain $chain_index · $(phase.name)"

"""
    TermHandle

The mutable state behind [`TermBackend`](@ref MCMCProgress.TermBackend): the
`Term.Progress.ProgressBar` the run draws into, a pristine copy of its column
configuration, and the `Term.Progress.ProgressJob` open for each phase, keyed
by the phase's own `id`.

`template_columns` exists because a freshly added job's `columns` field
starts out as the very array held by `pbar.columns`, not a copy of it, and
`ProgressJob.start!` mutates that array in place — filtering out the bar
column and pushing a spinner column onto it — whenever the job's total is
`nothing`. Left alone, the first such job added to a bar would permanently
strip the bar column from every job added afterward. Resetting `pbar.columns`
to a fresh copy of `template_columns` before every `addjob!` call keeps one
phase's columns from leaking into another's.
"""
struct TermHandle
    pbar::ProgressBar
    template_columns::Vector{DataType}
    jobs::Dict{UInt,ProgressJob}
end

function setup(backend::TermBackend, snapshot::RunSnapshot)
    pbar = ProgressBar(;
        columns=_columns(backend),
        columns_kwargs=backend.columns_kwargs,
        title=snapshot.label,
    )
    start!(pbar)
    return TermHandle(pbar, copy(pbar.columns), Dict{UInt,ProgressJob}())
end

function phase_opened(handle::TermHandle, chain_index::Integer, phase::PhaseSnapshot)
    handle.pbar.columns = copy(handle.template_columns)
    job =
        addjob!(handle.pbar; description=_description(chain_index, phase), N=_total(phase))
    handle.jobs[phase.id] = job
    return nothing
end

# A finished job ignores a further position: `ProgressJob.update!` reads that
# as a request to stop the job again rather than as a new position once its
# count already reached its total.
_setposition!(job::ProgressJob, position::Integer) =
    (job.finished || update!(job; i=position); nothing)

function phase_closed(handle::TermHandle, chain_index::Integer, phase::PhaseSnapshot)
    job = pop!(handle.jobs, phase.id)
    _setposition!(job, phase.position)
    removejob!(handle.pbar, job)
    return nothing
end

function refresh(handle::TermHandle, snapshot::RunSnapshot)
    for chain in snapshot.chains
        for phase in chain.phases
            phase.closed === nothing || continue
            _setposition!(handle.jobs[phase.id], phase.position)
        end
    end
    render(handle.pbar)
    return nothing
end

teardown(handle::TermHandle, ::RunSnapshot) = stop!(handle.pbar)

end
