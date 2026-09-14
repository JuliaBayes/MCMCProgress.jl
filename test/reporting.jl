@testset "chain rejects an index the run does not have" begin
    r = MCMCProgress.Run("Sampling mymodel", 3)
    @test_throws "there is no chain 4" chain(r, 4)
    @test_throws "there is no chain 0" chain(r, 0)
end

@testset "a phase is opened, advanced, and closed" begin
    r = MCMCProgress.Run("Sampling mymodel", 1)
    c = chain(r, 1)

    p = openphase!(c, "Warmup", Determinate(1000))
    @test c.phases == [p]
    @test isopen(p)
    @test p.closed === nothing

    advance!(p, 500)
    @test p.position == 500

    closephase!(p)
    @test !isopen(p)
    @test p.closed isa UInt64
    @test p.closed >= p.opened
    @test p.position == 500
end

@testset "advance! sets an absolute position" begin
    r = MCMCProgress.Run("Sampling mymodel", 1)
    p = openphase!(chain(r, 1), "Adapting", Counting())

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
    c = chain(r, 1)
    p = openphase!(c, "Finding step size", Binary())

    @test advance!(p, 7) === nothing
    @test p.position == 0
    # A binary phase has no position to get wrong, so even a nonsensical
    # report is accepted and discarded.
    @test advance!(p, -1) === nothing
    closephase!(p)
    @test advance!(p, 7) === nothing
    @test p.position == 0
end

@testset "reporting rejects what it cannot represent" begin
    r = MCMCProgress.Run("Sampling mymodel", 2)
    c = chain(r, 1)

    d = openphase!(c, "Warmup", Determinate(1000))
    @test_throws "runs for 1000 iterations, so it cannot advance to 1001" advance!(d, 1001)
    @test_throws "runs for 1000 iterations, so it cannot advance to -1" advance!(d, -1)
    @test d.position == 0

    @test_throws "still has the phase \"Warmup\" open" openphase!(c, "Sampling", Counting())

    closephase!(d)
    @test_throws "is closed, so it cannot advance to 5" advance!(d, 5)
    @test_throws "has already been closed" closephase!(d)

    n = openphase!(c, "Adapting", Counting())
    @test_throws "a position cannot be negative" advance!(n, -1)
    closephase!(n)

    MCMCProgress.setoutcome!(c, finished)
    @test_throws "has already ended as finished" openphase!(c, "Sampling", Counting())
    @test_throws "has already ended as finished" MCMCProgress.setoutcome!(c, failed)
end

@testset "teardown closes open phases and ends chains" begin
    r = MCMCProgress.Run("Sampling mymodel", 2)
    c1, c2 = chain(r, 1), chain(r, 2)

    done = openphase!(c1, "Finding step size", Binary())
    closephase!(done)
    left_open = openphase!(c1, "Warmup", Determinate(1000))
    advance!(left_open, 250)

    closed_earlier = done.closed
    MCMCProgress.closeopenphases!(c1)
    @test !isopen(left_open)
    @test left_open.closed isa UInt64
    @test left_open.position == 250
    # The phase that was already closed keeps the time it was closed at.
    @test done.closed === closed_earlier

    # A chain with nothing open is left as it is.
    MCMCProgress.closeopenphases!(c2)
    @test isempty(c2.phases)

    MCMCProgress.setoutcome!(c1, failed)
    MCMCProgress.setoutcome!(c2, interrupted)
    @test c1.outcome == failed
    @test c2.outcome == interrupted
end

@testset "a snapshot copies live state without sharing it" begin
    r = MCMCProgress.Run("Sampling mymodel", 2)
    c = chain(r, 1)
    p = openphase!(c, "Warmup", Determinate(1000))
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
    closephase!(p)
    MCMCProgress.setoutcome!(c, finished)
    @test s.chains[1].phases[1].position == 250
    @test s.chains[1].phases[1].closed === nothing
    @test s.chains[1].outcome === nothing

    later = MCMCProgress.snapshot(r)
    @test later.chains[1].phases[1].position == 1000
    @test later.chains[1].phases[1].closed isa UInt64
    @test later.chains[1].outcome == finished

    # Two phases sharing a name are still told apart by their identity.
    c2 = chain(r, 2)
    a = openphase!(c2, "Adapting", Counting())
    closephase!(a)
    b = openphase!(c2, "Adapting", Counting())
    sc = MCMCProgress.snapshot(c2)
    @test sc.phases[1].name == sc.phases[2].name
    @test sc.phases[1].id != sc.phases[2].id
    @test sc.phases[1].id == objectid(a)
    @test sc.phases[2].id == objectid(b)
end

@testset "a held chain lock delays neither advance! nor another chain" begin
    r = MCMCProgress.Run("Sampling mymodel", 2)
    c1, c2 = chain(r, 1), chain(r, 2)
    p1 = openphase!(c1, "Warmup", Determinate(10))
    done = Threads.Atomic{Bool}(false)

    # Hold the lock guarding chain 1's structure while another task reports a
    # position on chain 1 and runs a phase on chain 2. Neither needs that lock,
    # so both finish while it is held.
    lock(c1.lock) do
        wait(Threads.@spawn begin
            advance!(p1, 7)
            p2 = openphase!(c2, "Warmup", Counting())
            advance!(p2, 3)
            closephase!(p2)
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

    # Each chain reports its own positions and, every so often, snapshots the
    # whole run, so a snapshot is read on one task while the other chains write
    # on theirs.
    records = map(1:nchains) do j
        Threads.@spawn begin
            c = chain(r, j)
            b = openphase!(c, "Finding step size", Binary())
            advance!(b, 1)
            closephase!(b)
            w = openphase!(c, "Warmup", Determinate(total))
            mine = RunSnapshot[]
            for i in 1:total
                advance!(w, i)
                i % every == 0 && push!(mine, MCMCProgress.snapshot(r))
            end
            closephase!(w)
            MCMCProgress.setoutcome!(c, finished)
            mine
        end
    end

    # Each chain's snapshots in the order it took them, and all of them together.
    perchain = map(fetch, records)
    seen = reduce(vcat, perchain)
    push!(seen, MCMCProgress.snapshot(r))

    @test !isempty(seen)
    names = ["Finding step size", "Warmup"]

    # Only a snapshot taken while two chains were both partway through a phase
    # says anything about reading live state as it changes, so the count of
    # those is reported alongside the assertions below.
    reporting(cs) = any(ps -> ps.closed === nothing && 0 < ps.position < total, cs.phases)
    overlapping = count(s -> count(reporting, s.chains) >= 2, seen)
    if overlapping == 0
        @warn "none of the $(length(seen)) snapshots caught two chains reporting at once, so on $(Threads.nthreads()) thread(s) this testset saw chains take turns rather than overlap"
    else
        @info "$overlapping of $(length(seen)) snapshots caught two or more chains reporting at once across $(Threads.nthreads()) threads"
    end

    # What one snapshot must show: a prefix of the phases the chain will open,
    # none out of order or partly built, and a closed phase carrying the position
    # it finished on, since the lock that publishes the closing time also
    # publishes the last position stored before it.
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

    # Two snapshots one chain took in succession: every other chain only gains
    # phases and advances positions, never losing a phase, going backwards, or
    # reopening something already closed.
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

    # Reported as the first offending index rather than as one assertion per
    # snapshot, so a torn read names the snapshot it came from once.
    @test findfirst(!consistent, seen) === nothing
    @test findfirst(pair -> !monotonic(pair...), successive) === nothing

    final = last(seen)
    @test [length(cs.phases) for cs in final.chains] == fill(2, nchains)
    @test [cs.outcome for cs in final.chains] == fill(finished, nchains)
    @test [cs.phases[2].position for cs in final.chains] == fill(total, nchains)
    @test all(ps.closed isa UInt64 for cs in final.chains for ps in cs.phases)
end
