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
bar from when given no explicit column configuration: a description, the bar
itself, the position and percentage for a determinate phase, and an estimate of
the time remaining. There is no column for elapsed time, which would leave too
little width to read at several chains wide.

This one list serves every phase kind. For a phase with no total,
`ProgressJob.start!` removes `ProgressColumn` and adds Term's spinner column,
and `PercentageColumn` and `ETAColumn` render blank once a job's `N` is
`nothing`.
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

# A bar has nowhere else to say which chain it belongs to, so the chain index
# goes alongside the name of the phase the chain is in.
_description(chain_index::Integer) = "chain $chain_index"
_description(
    chain_index::Integer,
    phase::PhaseSnapshot,
) = "chain $chain_index · $(phase.name)"

"""
    TermHandle

The mutable state behind [`TermBackend`](@ref MCMCProgress.TermBackend): the
`Term.Progress.ProgressBar` the run draws into, a pristine copy of its column
configuration, and one `Term.Progress.ProgressJob` per chain, keyed by the
chain's index.

Every job is created before the bar starts, and none is added or removed while
it runs. Term scrolls the terminal for each job added to a running bar, and
identifies a job to remove by an `id` derived from how many jobs the bar holds,
so adding or removing jobs mid-run scrolls the terminal at every phase boundary
and deletes the wrong chain's bar. A chain runs one phase at a time, so one bar
per chain shows everything there is to show.

`template_columns` is needed because a freshly added job's `columns` field
starts out as the array held by `pbar.columns` rather than a copy of it, and
`ProgressJob.start!` mutates that array in place whenever the job's total is
`nothing`, filtering out the bar column and pushing a spinner column onto it.
Every job gets a fresh copy, which keeps one chain's columns out of another's
and rebuilds the columns each new phase needs.
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
    # Starting the bar after its jobs exist is what makes room for all of them
    # in one go; a job added to a bar already running scrolls the terminal.
    start!(pbar)
    return TermHandle(pbar, template_columns, jobs)
end

# Point a chain's job at a new phase: fresh columns for the phase's kind, the
# position back to zero, and a fresh `startime` from `ProgressJob.start!`, so
# the estimate of the time remaining is timed from this phase and not from the
# phase the chain was in before.
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

# The position is stored straight onto the job rather than through
# `ProgressJob.update!`, which reads a position given to a job already at its
# total as a request to stop the job, and `ProgressJob.stop!` sleeps for 50 ms:
# on the refresh task, 50 ms in which nothing is drawn.
_setposition!(job::ProgressJob, position::Integer) = (job.i=position; nothing)

function phase_closed(handle::TermHandle, chain_index::Integer, phase::PhaseSnapshot)
    job = handle.jobs[chain_index]
    _setposition!(job, phase.position)
    # `finished` settles a spinner column on its tick. The job stays in place,
    # so the chain's last phase remains visible until it opens another.
    job.finished = true
    return nothing
end

function refresh(handle::TermHandle, snapshot::RunSnapshot)
    for chain in snapshot.chains
        for phase in chain.phases
            phase.closed === nothing || continue
            _setposition!(handle.jobs[chain.index], phase.position)
        end
    end
    render(handle.pbar)
    return nothing
end

# The refresh task has stopped by the time a run is torn down, so this render is
# what puts every chain's closing position on the screen. Without it the display
# keeps what the last refresh drew, up to a refresh period short of where the
# run ended.
function teardown(handle::TermHandle, ::RunSnapshot)
    render(handle.pbar)
    stop!(handle.pbar)
    return nothing
end

end
