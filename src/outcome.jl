"""
    Outcome

How a chain or a run ended: `finished`, `failed`, or `interrupted`. A chain that
is still running has no outcome yet, represented as `nothing` rather than a
fourth value.
"""
@enum Outcome finished failed interrupted
