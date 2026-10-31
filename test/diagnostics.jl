struct DiagnosticsObserver
    snapshots::Channel{RunSnapshot}
end
MCMCProgress.setup(backend::DiagnosticsObserver, ::RunSnapshot) = backend
function MCMCProgress.refresh(backend::DiagnosticsObserver, snapshot::RunSnapshot)
    return put!(backend.snapshots, snapshot)
end
MCMCProgress.teardown(::DiagnosticsObserver, ::RunSnapshot) = nothing

function await_display(channel)
    timedwait(() -> isready(channel), 10.0) === :ok || error("display did not respond")
    return take!(channel)
end

struct UnprintableDiagnostic end
Base.print(::IO, ::UnprintableDiagnostic) = error("cannot print diagnostic")

struct ZeroBasedRows{T} <: AbstractVector{T}
    rows::Vector{T}
end
Base.size(rows::ZeroBasedRows) = size(rows.rows)
Base.axes(rows::ZeroBasedRows) = (0:(length(rows) - 1),)
Base.getindex(rows::ZeroBasedRows, i::Int) = rows.rows[i + 1]
Base.copy(rows::ZeroBasedRows) = ZeroBasedRows(copy(rows.rows))

@testset "diagnostics are shared, owned snapshots with live and final text" begin
    left, right = MCMCProgress.RecordingBackend(), MCMCProgress.RecordingBackend()
    observer = DiagnosticsObserver(Channel{RunSnapshot}(Inf))
    io, calls = IOBuffer(), Ref(0)
    live = ""
    rows = [(draws=0, divergences=0), (draws=0, divergences=2)]
    source = () -> begin
        calls[] += 1
        rows[1] = (draws=calls[], divergences=0)
        rows[2] = (draws=calls[], divergences=2)
        rows
    end
    progress(;
        label="Health",
        nchains=2,
        diagnostics=source,
        backend=(PlainTextBackend(io), left, right, observer),
    ) do run
        open_phase!(chain_at(run, 1), "Sampling", Binary())
        while isempty(await_display(observer.snapshots).chains[1].phases)
        end
        live = String(take!(io))
    end
    snapshots = [call[2] for call in left.calls if call[1] in (:refresh, :teardown)]
    @test all(a === b for (a, b) in zip(left.calls, right.calls))
    @test calls[] == length(snapshots)
    @test first(snapshots).diagnostics[1].draws == 1
    @test Tuple(last(snapshots).diagnostics) ==
        ((draws=calls[], divergences=0), (draws=calls[], divergences=2))
    rows[1] = (draws=999, divergences=999)
    @test first(snapshots).diagnostics[1] == (draws=1, divergences=0)
    @test length(split(live, '\n'; keepempty=false)) == 1
    @test occursin("Sampling", live) && occursin("divergences=0", live)
    text = String(take!(io))
    @test occursin("finished", text) && occursin("draws=$(calls[]), divergences=2", text)
end

@testset "diagnostic vectors follow chain order regardless of indices or element type" begin
    for rows in ([(value=11,), (value=22,)], Any[(value=11,), (value=22,)])
        io = IOBuffer()
        progress(
            _ -> nothing;
            label="Rows",
            nchains=2,
            backend=PlainTextBackend(io),
            diagnostics=()->ZeroBasedRows(rows),
        )
        lines = split(String(take!(io)), '\n'; keepempty=false)
        @test occursin("chain 1/2", lines[1]) && occursin("value=11", lines[1])
        @test occursin("chain 2/2", lines[2]) && occursin("value=22", lines[2])
    end
end

@testset "a failed final diagnostics source still cleans up displays" begin
    for fail_body in (false, true)
        recorder = MCMCProgress.RecordingBackend()
        body_error = ErrorException("sampling failed")
        caller = current_task()
        source = () -> begin
            current_task() === caller || return ((;),)
            return fail_body ? error("diagnostics failed") : ()
        end
        caught = nothing
        output = loudly() do
            Logging.with_logger(Logging.NullLogger()) do
                try
                    progress(;
                        label="Health",
                        nchains=1,
                        backend=(TermBackend(), recorder),
                        diagnostics=source,
                    ) do run
                        open_phase!(chain_at(run, 1), "Sampling", Counting())
                        fail_body && throw(body_error)
                    end
                catch exception
                    caught = exception
                end
            end
        end
        @test fail_body ? caught === body_error : caught isa ArgumentError
        @test occursin("\e[?25h", output)
        @test last(recorder.calls)[1] == :teardown
        @test last(recorder.calls)[2].chains[1].outcome == (fail_body ? failed : finished)
    end
end

@testset "Term keeps diagnostic entries within one row and the bar width" begin
    initial = run_snapshot(10)
    rows = ntuple(10) do chain
        chain == 1 && return (status="first\nsecond\t" * repeat("x", 100),)
        return chain == 10 ? (status="last",) : (;)
    end
    handle = quietly(() -> setup(TermBackend(), initial))
    snapshot = RunSnapshot(initial.label, initial.chains, rows)
    output = loudly(() -> refresh(handle, snapshot))
    quietly(() -> teardown(handle, snapshot))
    plain = replace(output, r"\e\[[0-9;?]*[A-Za-z]"=>"")
    lines = filter(line -> occursin(" : status=", line), split(plain, '\n'))
    @test length(lines) == 2
    @test occursin("first second ", plain)
    @test all(line -> textwidth(line) <= handle.pbar.width, lines)
end

@testset "a diagnostics refresh failure permits sampling to finish" begin
    called = Channel{Nothing}(1)
    recorder, completed = MCMCProgress.RecordingBackend(), Ref(false)
    source = () -> begin
        put!(called, nothing)
        error("diagnostics failed")
    end
    Logging.with_logger(Logging.NullLogger()) do
        @test_throws TaskFailedException progress(;
            label="Health", nchains=1, backend=recorder, diagnostics=source
        ) do run
            await_display(called)
            completed[] = true
        end
    end
    @test completed[]
    @test last(recorder.calls)[1] == :teardown
end

@testset "Term shows current diagnostics without changing its progress clock" begin
    run = RunProgress("Health", 1)
    phase = open_phase!(chain_at(run, 1), "Sampling", Determinate(10))
    handle = quietly(() -> setup(TermBackend(), RunSnapshot(run)))
    quietly(() -> phase_opened(handle, 1, PhaseSnapshot(phase)))
    started = handle.jobs[1].startime
    for count in (1, 2)
        snapshot = RunSnapshot(run.label, RunSnapshot(run).chains, ((divergences=count,),))
        output = loudly(() -> refresh(handle, snapshot))
        @test occursin("divergences=$count", output)
    end
    @test handle.jobs[1].startime == started
    final = RunSnapshot(run.label, RunSnapshot(run).chains, ((divergences=3,),))
    @test occursin("divergences=3", loudly(() -> teardown(handle, final)))

    handle = quietly(() -> setup(TermBackend(), RunSnapshot(run)))
    broken = RunSnapshot(
        run.label, RunSnapshot(run).chains, ((value=UnprintableDiagnostic(),),)
    )
    output = loudly() do
        @test_throws "cannot print diagnostic" teardown(handle, broken)
    end
    @test occursin("\e[?25h", output)
end
