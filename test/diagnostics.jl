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
        ZeroBasedRows(rows)
    end
    quick_run(
        (PlainTextBackend(io), left, right, observer); nchains=2, diagnostics=source
    ) do run
        open_phase!(chain_at(run, 1), "Sampling", Binary())
        while isempty(await_display(observer.snapshots).chains[1].phases)
        end
        live = String(take!(io))
    end
    snapshots = [call[2] for call in left.calls if call[1] in (:refresh, :teardown)]
    @test all(a === b for (a, b) in zip(left.calls, right.calls))
    @test calls[] == length(snapshots)
    @test Tuple(last(snapshots).diagnostics) ==
        ((draws=calls[], divergences=0), (draws=calls[], divergences=2))
    rows[1] = (draws=999, divergences=999)
    @test first(snapshots).diagnostics[1] == (draws=1, divergences=0)
    @test length(split(live, '\n'; keepempty=false)) == 1
    @test occursin("Sampling", live) && occursin("divergences=0", live)
    text = String(take!(io))
    @test occursin("finished", text) && occursin("draws=$(calls[]), divergences=2", text)
end

@testset "diagnostic vectors accept named tuples with an abstract element type" begin
    io = IOBuffer()
    progress(
        _ -> nothing;
        label="Rows",
        nchains=2,
        backend=PlainTextBackend(io),
        diagnostics=()->ZeroBasedRows(Any[(value=11,), (value=22,)]),
    )
    lines = split(String(take!(io)), '\n'; keepempty=false)
    @test occursin("chain 1/2", lines[1]) && occursin("value=11", lines[1])
    @test occursin("chain 2/2", lines[2]) && occursin("value=22", lines[2])
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
        caught = Logging.with_logger(Logging.NullLogger()) do
            try
                quick_run(recorder; diagnostics=source) do run
                    open_phase!(chain_at(run, 1), "Sampling", Counting())
                    fail_body && throw(body_error)
                end
            catch exception
                exception
            end
        end
        @test fail_body ? caught === body_error : caught isa ArgumentError
        @test last(call_names(recorder)) == :teardown
        @test final_snapshot(recorder).diagnostics === nothing
        @test only(final_snapshot(recorder).chains[1].phases).closed !== nothing
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
    final = RunSnapshot(initial.label, initial.chains, ntuple(_ -> (status="final",), 10))
    @test occursin("status=final", loudly(() -> teardown(handle, final)))
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
        @test_throws TaskFailedException quick_run(recorder; diagnostics=source) do run
            await_display(called)
            completed[] = true
        end
    end
    @test completed[]
    @test last(recorder.calls)[1] == :teardown
end

@testset "Term restores the cursor when formatting diagnostics fails" begin
    snapshot = run_snapshot(1)
    handle = quietly(() -> setup(TermBackend(), snapshot))
    broken =
        RunSnapshot(snapshot.label, snapshot.chains, ((value=UnprintableDiagnostic(),),))
    output = loudly() do
        @test_throws "cannot print diagnostic" teardown(handle, broken)
    end
    @test occursin("\e[?25h", output)
end
