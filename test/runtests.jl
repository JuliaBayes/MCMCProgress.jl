using MCMCProgress
using Test
using ProgressLogging: ProgressLogging
using Logging: Logging
using Term: Term
using Dates: Dates

@testset "MCMCProgress.jl" begin

    @testset "a determinate phase rejects a negative total" begin
        @test_throws "must be non-negative" Determinate(-1)
    end

    @testset "a run numbers its chains from one" begin
        @test_throws "at least 1" MCMCProgress.Chain(0)
        @test_throws "at least one chain" MCMCProgress.Run("empty", 0)
        r = MCMCProgress.Run("Sampling mymodel", 3)
        @test [ch.index for ch in r.chains] == [1, 2, 3]
    end

    include("reporting.jl")
    include("plaintext.jl")
    include("scope.jl")
    include("progresslogging.jl")
    include("term.jl")
    include("callback_sampler.jl")

    @testset "show methods for snapshot types" begin
        r = MCMCProgress.Run("Sampling mymodel", 1)
        c = r.chains[1]
        pd = MCMCProgress.Phase("Warmup", Determinate(1000))
        advance!(pd, 500)
        pc = MCMCProgress.Phase("Adapting", Counting())
        advance!(pc, 7)
        pb = MCMCProgress.Phase("Finding step size", Binary())
        push!(c.phases, pd)
        push!(c.phases, pc)
        push!(c.phases, pb)

        psd =
            PhaseSnapshot(objectid(pd), pd.name, pd.kind, pd.position, pd.opened, pd.closed)
        psc =
            PhaseSnapshot(objectid(pc), pc.name, pc.kind, pc.position, pc.opened, pc.closed)
        psb =
            PhaseSnapshot(objectid(pb), pb.name, pb.kind, pb.position, pb.opened, pb.closed)
        cs = ChainSnapshot(c.index, [psd, psc, psb], nothing)
        rs = RunSnapshot(r.label, [cs])

        @test occursin("500/1000", sprint(show, psd))
        @test occursin("7", sprint(show, psc))
        @test !occursin("/", sprint(show, psb))  # binary phases show no position
        @test occursin("open", sprint(show, psd))

        @test occursin("3 phases", sprint(show, cs))

        @test occursin("Sampling mymodel", sprint(show, rs))
        plaintext = sprint(io -> show(io, MIME"text/plain"(), rs))
        @test occursin("Warmup", plaintext)
        @test occursin("Adapting", plaintext)
        @test occursin("Finding step size", plaintext)
    end

    @testset "phase_opened and phase_closed default to no-ops" begin
        if !isdefined(@__MODULE__, :NoOpTestBackend)
            struct NoOpTestBackend end
        end
        p = MCMCProgress.Phase("Warmup", Determinate(10))
        ps = PhaseSnapshot(objectid(p), p.name, p.kind, p.position, p.opened, p.closed)
        @test MCMCProgress.phase_opened(NoOpTestBackend(), 1, ps) === nothing
        @test MCMCProgress.phase_closed(NoOpTestBackend(), 1, ps) === nothing
    end

    @testset "backend selection precedence" begin
        saved_default = MCMCProgress._DEFAULT_BACKEND[]
        try
            MCMCProgress._DEFAULT_BACKEND[] = nothing
            @test MCMCProgress.resolve_backend() isa PlainTextBackend

            default_backend = MCMCProgress.RecordingBackend()
            setbackend!(default_backend)
            @test MCMCProgress.resolve_backend() === default_backend  # falls back to the process-wide default

            explicit_backend = MCMCProgress.RecordingBackend()
            @test MCMCProgress.resolve_backend(explicit_backend) === explicit_backend  # explicit argument wins
        finally
            MCMCProgress._DEFAULT_BACKEND[] = saved_default
        end
    end

    @testset "clear error for a backend whose extension is not loaded" begin
        if !isdefined(@__MODULE__, :UnloadedExtBackend)
            struct UnloadedExtBackend end
        end
        MCMCProgress.backend_package(::UnloadedExtBackend) = "FakeExtPackage"

        @test_throws "FakeExtPackage" MCMCProgress.resolve_backend(UnloadedExtBackend())
        @test_throws "FakeExtPackage" setbackend!(UnloadedExtBackend())
    end

end
