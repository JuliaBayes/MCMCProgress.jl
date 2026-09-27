abstract type PhaseKind end

"""
    Determinate(total)

A phase whose total number of iterations is known ahead of time, such as a warmup run for a
fixed number of steps.
"""
struct Determinate <: PhaseKind
    total::Int

    function Determinate(total::Int)
        total >= 0 || throw(
            ArgumentError("a determinate phase's total must be non-negative, got $total"),
        )
        new(total)
    end
end

"""
    Counting()

A phase that reports a rising count but with no known total, such as an adaptation which
stops when certain numerical criteria are met.
"""
struct Counting <: PhaseKind end

"""
    Binary()

A phase with no count at all: it is either running or over.
"""
struct Binary <: PhaseKind end
