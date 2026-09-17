@testset "chain_at rejects an index the run does not have" begin
    r = MCMCProgress.Run("Sampling mymodel", 3)
    @test_throws BoundsError chain_at(r, 4)
    @test_throws BoundsError chain_at(r, 0)
end

@testset "a phase is opened, advanced, and closed" begin
    r = MCMCProgress.Run("Sampling mymodel", 1)
    c = chain_at(r, 1)

    p = open_phase!(c, "Warmup", Determinate(1000))
    @test c.phases == [p]
    @test isopen(p)
    @test p.closed === nothing

    advance!(p, 500)
    @test p.position == 500

    close_phase!(p)
    @test !isopen(p)
    @test p.closed isa UInt64
    @test p.closed >= p.opened
    @test p.position == 500
end

@testset "advance! sets an absolute position" begin
    r = MCMCProgress.Run("Sampling mymodel", 1)
    p = open_phase!(chain_at(r, 1), "Adapting", Counting())

    advance!(p, 5)
    @test p.position == 5
    # Repeating a report leaves the position where it was, rather than adding.
    advance!(p, 5)
    @test p.position == 5
    advance!(p, 9)
    @test p.position == 9
    # Positions are not required to arrive one at a time.
    advance!(p, 100)
    @test p.position == 100
end

@testset "advance! on a binary phase does nothing" begin
    r = MCMCProgress.Run("Sampling mymodel", 1)
    c = chain_at(r, 1)
    p = open_phase!(c, "Finding step size", Binary())

    @test advance!(p, 7) === nothing
    @test p.position == 0
    # Even a negative position is ignored.
    @test advance!(p, -1) === nothing
    close_phase!(p)
    @test advance!(p, 7) === nothing
    @test p.position == 0
end

@testset "reporting rejects what it cannot represent" begin
    r = MCMCProgress.Run("Sampling mymodel", 2)
    c = chain_at(r, 1)

    d = open_phase!(c, "Warmup", Determinate(1000))
    @test_throws "runs for 1000 iterations, so it cannot advance to 1001" advance!(d, 1001)
    @test_throws "runs for 1000 iterations, so it cannot advance to -1" advance!(d, -1)
    @test d.position == 0

    @test_throws "still has the phase \"Warmup\" open" open_phase!(
        c,
        "Sampling",
        Counting(),
    )

    close_phase!(d)
    @test_throws "is closed, so it cannot advance to 5" advance!(d, 5)
    @test_throws "has already been closed" close_phase!(d)

    n = open_phase!(c, "Adapting", Counting())
    @test_throws "a position cannot be negative" advance!(n, -1)
    close_phase!(n)

    MCMCProgress.set_outcome!(c, finished)
    @test_throws "has already ended as finished" open_phase!(c, "Sampling", Counting())
    @test_throws "has already ended as finished" MCMCProgress.set_outcome!(c, failed)
end

@testset "teardown closes open phases and ends chains" begin
    r = MCMCProgress.Run("Sampling mymodel", 2)
    c1, c2 = chain_at(r, 1), chain_at(r, 2)

    done = open_phase!(c1, "Finding step size", Binary())
    close_phase!(done)
    left_open = open_phase!(c1, "Warmup", Determinate(1000))
    advance!(left_open, 250)

    closed_earlier = done.closed
    MCMCProgress.close_open_phases!(c1)
    @test !isopen(left_open)
    @test left_open.closed isa UInt64
    @test left_open.position == 250
    # The phase that was already closed keeps the time it was closed at.
    @test done.closed === closed_earlier

    # A chain with nothing open is left as it is.
    MCMCProgress.close_open_phases!(c2)
    @test isempty(c2.phases)

    MCMCProgress.set_outcome!(c1, failed)
    MCMCProgress.set_outcome!(c2, interrupted)
    @test c1.outcome == failed
    @test c2.outcome == interrupted
end

@testset "a snapshot copies live state without sharing it" begin
    r = MCMCProgress.Run("Sampling mymodel", 2)
    c = chain_at(r, 1)
    p = open_phase!(c, "Warmup", Determinate(1000))
    advance!(p, 250)

    s = MCMCProgress.snapshot(r)
    @test s.label == "Sampling mymodel"
    @test length(s.chains) == 2
    @test s.chains[1].phases[1].id == objectid(p)
    @test s.chains[1].phases[1].position == 250
    @test s.chains[1].phases[1].closed === nothing
    @test s.chains[1].outcome === nothing
    @test isempty(s.chains[2].phases)

    # Advancing and closing afterwards leaves the copy alone.
    advance!(p, 1000)
    close_phase!(p)
    MCMCProgress.set_outcome!(c, finished)
    @test s.chains[1].phases[1].position == 250
    @test s.chains[1].phases[1].closed === nothing
    @test s.chains[1].outcome === nothing

    later = MCMCProgress.snapshot(r)
    @test later.chains[1].phases[1].position == 1000
    @test later.chains[1].phases[1].closed isa UInt64
    @test later.chains[1].outcome == finished

    # Two phases sharing a name are still told apart by their identity.
    c2 = chain_at(r, 2)
    a = open_phase!(c2, "Adapting", Counting())
    close_phase!(a)
    b = open_phase!(c2, "Adapting", Counting())
    sc = MCMCProgress.snapshot(c2)
    @test sc.phases[1].name == sc.phases[2].name
    @test sc.phases[1].id != sc.phases[2].id
    @test sc.phases[1].id == objectid(a)
    @test sc.phases[2].id == objectid(b)
end

@testset "a held chain lock delays neither advance! nor another chain" begin
    r = MCMCProgress.Run("Sampling mymodel", 2)
    c1, c2 = chain_at(r, 1), chain_at(r, 2)
    p1 = open_phase!(c1, "Warmup", Determinate(10))
    done = Threads.Atomic{Bool}(false)

    # Advancing chain 1 and running a phase on chain 2 must not need chain 1's lock.
    lock(c1.lock) do
        wait(Threads.@spawn begin
            advance!(p1, 7)
            p2 = open_phase!(c2, "Warmup", Counting())
            advance!(p2, 3)
            close_phase!(p2)
            done[] = true
        end)
    end

    @test done[]
    @test p1.position == 7
    @test length(c2.phases) == 1
    @test c2.phases[1].position == 3
    @test !isopen(c2.phases[1])
end

@testset "chains reporting concurrently stay consistent under snapshots" begin
    nchains = 4
    total = 200_000
    every = 2_000
    r = MCMCProgress.Run("Sampling mymodel", nchains)

    # Each chain snapshots the whole run periodically while the others write.
    records = map(1:nchains) do j
        Threads.@spawn begin
            c = chain_at(r, j)
            b = open_phase!(c, "Finding step size", Binary())
            advance!(b, 1)
            close_phase!(b)
            w = open_phase!(c, "Warmup", Determinate(total))
            mine = RunSnapshot[]
            for i in 1:total
                advance!(w, i)
                i % every == 0 && push!(mine, MCMCProgress.snapshot(r))
            end
            close_phase!(w)
            MCMCProgress.set_outcome!(c, finished)
            mine
        end
    end

    # Each chain's snapshots in the order it took them, and all of them together.
    perchain = map(fetch, records)
    seen = reduce(vcat, perchain)
    push!(seen, MCMCProgress.snapshot(r))

    @test !isempty(seen)
    names = ["Finding step size", "Warmup"]

    # Only snapshots with two chains mid-phase test concurrent reads; report how many.
    reporting(cs) = any(ps -> ps.closed === nothing && 0 < ps.position < total, cs.phases)
    overlapping = count(s -> count(reporting, s.chains) >= 2, seen)
    if overlapping == 0
        @warn "none of the $(length(seen)) snapshots caught two chains reporting at once, so on $(Threads.nthreads()) thread(s) this testset saw chains take turns rather than overlap"
    else
        @info "$overlapping of $(length(seen)) snapshots caught two or more chains reporting at once across $(Threads.nthreads()) threads"
    end

    # A snapshot shows a prefix of the expected phases, closed ones at their final position.
    function consistent(s::RunSnapshot)
        length(s.chains) == nchains || return false
        for (j, cs) in pairs(s.chains)
            cs.index == j || return false
            length(cs.phases) <= length(names) || return false
            for (k, ps) in pairs(cs.phases)
                ps.name == names[k] || return false
                if ps.kind == Binary()
                    ps.position == 0 || return false
                else
                    0 <= ps.position <= total || return false
                    ps.closed === nothing || ps.position == total || return false
                end
            end
            cs.outcome === nothing || cs.outcome == finished || return false
        end
        return true
    end

    # Between successive snapshots no chain loses a phase, moves back, or reopens one.
    function monotonic(earlier::RunSnapshot, later::RunSnapshot)
        for j in eachindex(earlier.chains)
            before, after = earlier.chains[j], later.chains[j]
            length(after.phases) >= length(before.phases) || return false
            for k in eachindex(before.phases)
                after.phases[k].id == before.phases[k].id || return false
                after.phases[k].position >= before.phases[k].position || return false
                before.phases[k].closed === nothing ||
                    after.phases[k].closed == before.phases[k].closed ||
                    return false
            end
        end
        return true
    end

    successive = [
        (earlier, later) for ordered in perchain for
        (earlier, later) in zip(ordered, Iterators.drop(ordered, 1))
    ]

    # `findfirst` reports one offending snapshot instead of one failure per snapshot.
    @test findfirst(!consistent, seen) === nothing
    @test findfirst(pair -> !monotonic(pair...), successive) === nothing

    final = last(seen)
    @test [length(cs.phases) for cs in final.chains] == fill(2, nchains)
    @test [cs.outcome for cs in final.chains] == fill(finished, nchains)
    @test [cs.phases[2].position for cs in final.chains] == fill(total, nchains)
    @test all(ps.closed isa UInt64 for cs in final.chains for ps in cs.phases)
end
