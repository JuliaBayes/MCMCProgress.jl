@testset "plain text line format for each phase kind" begin
    io = IOBuffer()
    clk = Ref(UInt64(0))
    backend = PlainTextBackend(io; now=() -> clk[])
    rs0 = RunSnapshot(
        "Sampling mymodel",
        [
            ChainSnapshot(1, PhaseSnapshot[], nothing),
            ChainSnapshot(2, PhaseSnapshot[], nothing),
        ],
    )
    handle = setup(backend, rs0)

    # Determinate: opening, a later refresh, and closing all show position,
    # total, and percentage.
    clk[] = UInt64(0)
    warmup_open = PhaseSnapshot(UInt(1), "Warmup", Determinate(1000), 0, UInt64(0), nothing)
    phase_opened(handle, 1, warmup_open)
    clk[] = UInt64(3_200_000_000)
    warmup_mid =
        PhaseSnapshot(UInt(1), "Warmup", Determinate(1000), 250, UInt64(0), nothing)
    refresh(
        handle,
        RunSnapshot(rs0.label, (ChainSnapshot(1, [warmup_mid], nothing), rs0.chains[2])),
    )
    warmup_closed = PhaseSnapshot(
        UInt(1),
        "Warmup",
        Determinate(1000),
        1000,
        UInt64(0),
        UInt64(4_000_000_000),
    )
    phase_closed(handle, 1, warmup_closed)

    # Counting: bare position and elapsed, never a total or percentage.
    clk[] = UInt64(0)
    counting_open = PhaseSnapshot(UInt(2), "Adapting", Counting(), 0, UInt64(0), nothing)
    phase_opened(handle, 2, counting_open)
    counting_closed =
        PhaseSnapshot(UInt(2), "Adapting", Counting(), 42, UInt64(0), UInt64(1_500_000_000))
    phase_closed(handle, 2, counting_closed)

    # Binary: name and elapsed only, never a position.
    clk[] = UInt64(0)
    binary_open =
        PhaseSnapshot(UInt(3), "Finding step size", Binary(), 0, UInt64(0), nothing)
    phase_opened(handle, 2, binary_open)
    binary_closed = PhaseSnapshot(
        UInt(3),
        "Finding step size",
        Binary(),
        0,
        UInt64(0),
        UInt64(100_000_000),
    )
    phase_closed(handle, 2, binary_closed)

    lines = split(String(take!(io)), '\n'; keepempty=false)
    @test lines == [
        "[Sampling mymodel] chain 1/2 · Warmup 0/1000 (0%) · 0.0s",
        "[Sampling mymodel] chain 1/2 · Warmup 250/1000 (25%) · 3.2s",
        "[Sampling mymodel] chain 1/2 · Warmup 1000/1000 (100%) · 4.0s",
        "[Sampling mymodel] chain 2/2 · Adapting 0 · 0.0s",
        "[Sampling mymodel] chain 2/2 · Adapting 42 · 1.5s",
        "[Sampling mymodel] chain 2/2 · Finding step size · 0.0s",
        "[Sampling mymodel] chain 2/2 · Finding step size · 0.1s",
    ]
end

@testset "refresh writes only when the displayed percentage bucket changes" begin
    # States the rule under test: a determinate phase's line is written again
    # only once its percentage has moved into a new five-point bucket (0, 5,
    # 10, … 100) since the last line written for that chain.
    io = IOBuffer()
    backend = PlainTextBackend(io)
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)
    opened_at = UInt64(0)
    phase_opened(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Warmup", Determinate(100), 0, opened_at, nothing),
    )

    # 1% through 4% stay in the same 0-4 bucket as the opening line: no new line.
    for i in 1:4
        cs = ChainSnapshot(
            1,
            [PhaseSnapshot(UInt(1), "Warmup", Determinate(100), i, opened_at, nothing)],
            nothing,
        )
        refresh(handle, RunSnapshot(rs0.label, (cs,)))
    end
    @test length(split(String(take!(io)), '\n'; keepempty=false)) == 1

    # 5% crosses into the next bucket: a new line is written.
    cs5 = ChainSnapshot(
        1,
        [PhaseSnapshot(UInt(1), "Warmup", Determinate(100), 5, opened_at, nothing)],
        nothing,
    )
    refresh(handle, RunSnapshot(rs0.label, (cs5,)))
    @test occursin("5/100 (5%)", String(take!(io)))
end

@testset "refresh writes a counting phase's line only when its position crosses the next multiple of a hundred" begin
    # States the rule under test: a counting phase has no total to compute a
    # percentage from, so its line is written again only once its position has
    # crossed the next multiple of a hundred since the last line written for
    # that chain.
    io = IOBuffer()
    backend = PlainTextBackend(io)
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)
    opened_at = UInt64(0)
    phase_opened(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Adapting", Counting(), 0, opened_at, nothing),
    )

    # 1 through 99 stay under the first multiple of a hundred: no new line.
    for i in 1:99
        cs = ChainSnapshot(
            1,
            [PhaseSnapshot(UInt(1), "Adapting", Counting(), i, opened_at, nothing)],
            nothing,
        )
        refresh(handle, RunSnapshot(rs0.label, (cs,)))
    end
    @test length(split(String(take!(io)), '\n'; keepempty=false)) == 1

    # 100 crosses into the next step: a new line is written.
    cs100 = ChainSnapshot(
        1,
        [PhaseSnapshot(UInt(1), "Adapting", Counting(), 100, opened_at, nothing)],
        nothing,
    )
    refresh(handle, RunSnapshot(rs0.label, (cs100,)))
    @test occursin("Adapting 100 ·", String(take!(io)))
end

@testset "refresh writes nothing further for a binary phase until it closes" begin
    io = IOBuffer()
    backend = PlainTextBackend(io)
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)
    opened_at = UInt64(0)
    phase_opened(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Finding step size", Binary(), 0, opened_at, nothing),
    )

    for _ in 1:5
        cs = ChainSnapshot(
            1,
            [PhaseSnapshot(UInt(1), "Finding step size", Binary(), 0, opened_at, nothing)],
            nothing,
        )
        refresh(handle, RunSnapshot(rs0.label, (cs,)))
    end
    @test length(split(String(take!(io)), '\n'; keepempty=false)) == 1  # only the opening line

    closed = PhaseSnapshot(
        UInt(1),
        "Finding step size",
        Binary(),
        0,
        opened_at,
        UInt64(500_000_000),
    )
    phase_closed(handle, 1, closed)
    @test length(split(String(take!(io)), '\n'; keepempty=false)) == 1  # the closing line
end

@testset "a counting phase advancing ten thousand positions writes about a hundred rising lines" begin
    io = IOBuffer()
    clk = Ref(UInt64(0))
    backend = PlainTextBackend(io; now=() -> clk[])
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)

    total = 10_000
    opened_at = UInt64(0)
    phase_opened(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Adapting", Counting(), 0, opened_at, nothing),
    )
    for i in 1:total
        clk[] = opened_at + UInt64(i) * UInt64(100_000)
        cs = ChainSnapshot(
            1,
            [PhaseSnapshot(UInt(1), "Adapting", Counting(), i, opened_at, nothing)],
            nothing,
        )
        refresh(handle, RunSnapshot(rs0.label, (cs,)))
    end
    closed_at = opened_at + UInt64(total) * UInt64(100_000)
    phase_closed(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Adapting", Counting(), total, opened_at, closed_at),
    )

    lines = split(String(take!(io)), '\n'; keepempty=false)
    @test 80 <= length(lines) <= 120

    positions = [parse(Int, match(r"Adapting (\d+) ·", line).captures[1]) for line in lines]
    @test issorted(positions; lt=(<))  # strictly rising, so no position repeats
    @test all(p -> p % 100 == 0, positions)
end

@testset "a counting phase that stops short of the next multiple of a hundred still gets its closing line with its true final position" begin
    io = IOBuffer()
    backend = PlainTextBackend(io)
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)
    opened_at = UInt64(0)
    phase_opened(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Adapting", Counting(), 0, opened_at, nothing),
    )
    closed_at = opened_at + UInt64(1_000_000_000)
    phase_closed(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Adapting", Counting(), 137, opened_at, closed_at),
    )

    lines = split(String(take!(io)), '\n'; keepempty=false)
    @test length(lines) == 2  # the opening line, then the closing line
    @test occursin("Adapting 137 ·", lines[end])
end

@testset "refresh coarsens a ten-thousand-iteration run to tens of lines" begin
    io = IOBuffer()
    clk = Ref(UInt64(0))
    backend = PlainTextBackend(io; now=() -> clk[])
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)

    total = 10_000
    opened_at = UInt64(0)
    phase_opened(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Sampling", Determinate(total), 0, opened_at, nothing),
    )
    for i in 1:total
        clk[] = opened_at + UInt64(i) * UInt64(100_000)
        cs = ChainSnapshot(
            1,
            [PhaseSnapshot(UInt(1), "Sampling", Determinate(total), i, opened_at, nothing)],
            nothing,
        )
        refresh(handle, RunSnapshot(rs0.label, (cs,)))
    end
    closed_at = opened_at + UInt64(total) * UInt64(100_000)
    phase_closed(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Sampling", Determinate(total), total, opened_at, closed_at),
    )

    lines = split(String(take!(io)), '\n'; keepempty=false)
    @test 10 <= length(lines) < 100
end

@testset "plain text output is byte-identical to an IOBuffer and a file" begin
    build_lines = function (io)
        clk = Ref(UInt64(0))
        backend = PlainTextBackend(io; now=() -> clk[])
        rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
        handle = setup(backend, rs0)
        phase_opened(
            handle,
            1,
            PhaseSnapshot(UInt(1), "Warmup", Determinate(10), 0, UInt64(0), nothing),
        )
        clk[] = UInt64(1_000_000_000)
        cs = ChainSnapshot(
            1,
            [PhaseSnapshot(UInt(1), "Warmup", Determinate(10), 5, UInt64(0), nothing)],
            nothing,
        )
        refresh(handle, RunSnapshot(rs0.label, (cs,)))
        closed = PhaseSnapshot(
            UInt(1),
            "Warmup",
            Determinate(10),
            10,
            UInt64(0),
            UInt64(2_000_000_000),
        )
        phase_closed(handle, 1, closed)
        teardown(handle, RunSnapshot(rs0.label, (ChainSnapshot(1, [closed], finished),)))
        return nothing
    end

    iobuf = IOBuffer()
    build_lines(iobuf)
    buffer_bytes = take!(iobuf)

    path, file = mktemp()
    try
        build_lines(file)
        close(file)
        @test read(path) == buffer_bytes
    finally
        rm(path; force=true)
    end
end

@testset "a failed or interrupted run records that in its final lines" begin
    for outcome in (failed, interrupted)
        io = IOBuffer()
        backend = PlainTextBackend(io)
        rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
        handle = setup(backend, rs0)
        p = PhaseSnapshot(
            UInt(1),
            "Warmup",
            Determinate(10),
            3,
            UInt64(0),
            UInt64(1_000_000_000),
        )
        phase_closed(handle, 1, p)
        teardown(handle, RunSnapshot(rs0.label, (ChainSnapshot(1, [p], outcome),)))

        @test occursin(string(outcome), String(take!(io)))
    end
end

@testset "plain text never emits ANSI escapes" begin
    io = IOBuffer()
    clk = Ref(UInt64(0))
    backend = PlainTextBackend(io; now=() -> clk[])
    rs0 = RunSnapshot("Sampling mymodel", [ChainSnapshot(1, PhaseSnapshot[], nothing)])
    handle = setup(backend, rs0)

    phase_opened(
        handle,
        1,
        PhaseSnapshot(UInt(1), "Warmup", Determinate(10), 0, UInt64(0), nothing),
    )
    clk[] = UInt64(500_000_000)
    cs = ChainSnapshot(
        1,
        [PhaseSnapshot(UInt(1), "Warmup", Determinate(10), 6, UInt64(0), nothing)],
        nothing,
    )
    refresh(handle, RunSnapshot(rs0.label, (cs,)))
    closed = PhaseSnapshot(
        UInt(1),
        "Warmup",
        Determinate(10),
        10,
        UInt64(0),
        UInt64(1_000_000_000),
    )
    phase_closed(handle, 1, closed)
    teardown(handle, RunSnapshot(rs0.label, (ChainSnapshot(1, [closed], failed),)))

    out = String(take!(io))
    @test !occursin('\e', out)
    @test !occursin("\x1b[", out)
end
