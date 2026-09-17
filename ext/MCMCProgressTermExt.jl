module MCMCProgressTermExt

using MCMCProgress: MCMCProgress, TermBackend, PhaseSnapshot, RunSnapshot, Determinate
import MCMCProgress: setup, phase_opened, phase_closed, refresh, teardown
using Term.Progress:
    ProgressBar,
    ProgressJob,
    addjob!,
    start!,
    stop!,
    render,
    DescriptionColumn,
    SeparatorColumn,
    ProgressColumn,
    CompletedColumn,
    PercentageColumn,
    ETAColumn

"""
    _DEFAULT_COLUMNS

The columns [`TermBackend`](@ref MCMCProgress.TermBackend) builds each chain's
bar from when given no column configuration: a description, the bar, the
position and percentage for a determinate phase, and an estimate of the time
remaining. There is no elapsed-time column, which would leave too little width
with several chains.

The list serves every phase kind. For a phase with no total,
`ProgressJob.start!` replaces `ProgressColumn` with a spinner column, and
`PercentageColumn` and `ETAColumn` render blank when a job's `N` is `nothing`.
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

# A job with no total gets a spinner from `ProgressJob.start!`.
_total(phase::PhaseSnapshot{Determinate}) = phase.kind.total
_total(::PhaseSnapshot) = nothing

# A bar has no other place to show its chain, so the description carries the
# chain index.
_description(chain_index::Integer) = "chain $chain_index"
_description(
    chain_index::Integer,
    phase::PhaseSnapshot,
) = "chain $chain_index · $(phase.name)"

"""
    TermHandle

The mutable state behind [`TermBackend`](@ref MCMCProgress.TermBackend): the
`Term.Progress.ProgressBar`, a copy of its initial columns, and one
`Term.Progress.ProgressJob` per chain index.

All jobs are created before the bar starts, and none is added or removed during
the run. Term scrolls the terminal for each job added to a running bar, and
identifies a job to remove by an `id` derived from the number of jobs, so
removing a job mid-run can delete another chain's bar.

A newly added job's `columns` is the same array as `pbar.columns`, and
`ProgressJob.start!` mutates it in place when the job's total is `nothing`,
replacing the bar column with a spinner. Each job therefore gets its own copy of
`template_columns`.
"""
struct TermHandle
    pbar::ProgressBar
    template_columns::Vector{DataType}
    jobs::Dict{Int,ProgressJob}
end

function setup(backend::TermBackend, snapshot::RunSnapshot)
    pbar = ProgressBar(;
        columns=_columns(backend),
        columns_kwargs=backend.columns_kwargs,
        title=snapshot.label,
    )
    template_columns = copy(pbar.columns)
    jobs = Dict{Int,ProgressJob}()
    for chain in snapshot.chains
        pbar.columns = copy(template_columns)
        jobs[chain.index] = addjob!(pbar; description=_description(chain.index))
    end
    # Starting the bar after adding its jobs reserves room for all of them at
    # once; a job added to a running bar scrolls the terminal.
    start!(pbar)
    return TermHandle(pbar, template_columns, jobs)
end

# Reset a chain's job for a new phase: fresh columns, position zero, and a new
# `startime` from `ProgressJob.start!`, so the time-remaining estimate starts
# from this phase.
function _restart!(handle::TermHandle, job::ProgressJob, description, total)
    job.description = description
    job.N = total
    job.i = 0
    job.finished = false
    job.stoptime = nothing
    job.started = false
    job.columns = copy(handle.template_columns)
    start!(job)
    return job
end

phase_opened(handle::TermHandle, chain_index::Integer, phase::PhaseSnapshot) = (
    _restart!(
        handle,
        handle.jobs[chain_index],
        _description(chain_index, phase),
        _total(phase),
    );
    nothing
)

# Sets `job.i` directly rather than through `ProgressJob.update!`, which stops a
# job already at its total, and `ProgressJob.stop!` sleeps for 50 ms on the
# refresh task.
_set_position!(job::ProgressJob, position::Integer) = (job.i=position; nothing)

function phase_closed(handle::TermHandle, chain_index::Integer, phase::PhaseSnapshot)
    job = handle.jobs[chain_index]
    _set_position!(job, phase.position)
    # `finished` makes a spinner column show its tick. The job is kept, so the
    # chain's last phase stays visible until it opens another.
    job.finished = true
    return nothing
end

function refresh(handle::TermHandle, snapshot::RunSnapshot)
    for chain in snapshot.chains
        for phase in chain.phases
            phase.closed === nothing || continue
            _set_position!(handle.jobs[chain.index], phase.position)
        end
    end
    render(handle.pbar)
    return nothing
end

# The refresh task has stopped before teardown, so this render is what draws
# each chain's final position.
function teardown(handle::TermHandle, ::RunSnapshot)
    render(handle.pbar)
    stop!(handle.pbar)
    return nothing
end

end
