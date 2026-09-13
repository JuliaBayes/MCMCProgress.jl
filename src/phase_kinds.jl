"""
    PhaseKind

What a phase can report about itself: whether its length is known, whether it
counts without a known length, or whether it has no count at all. A phase's kind
is fixed for its lifetime, so code can dispatch on the kind rather than branch on
a keyword.

See [`Determinate`](@ref), [`Counting`](@ref), [`Binary`](@ref).
"""
abstract type PhaseKind end

"""
    Determinate(total)

A phase whose total number of iterations is known when it opens, such as a
warmup run for a fixed number of steps.
"""
struct Determinate <: PhaseKind
    total::Int

    function Determinate(total::Integer)
        total >= 0 || throw(
            ArgumentError("a determinate phase's total must be non-negative, got $total"),
        )
        new(Int(total))
    end
end

"""
    Counting()

A phase that reports a rising count with no total, because the total stays
unknown even once the phase has begun — an adaptive stopping rule, for example.
"""
struct Counting <: PhaseKind end

"""
    Binary()

A phase with no count at all: it is either running or over. Position has no
meaning for a binary phase.
"""
struct Binary <: PhaseKind end
