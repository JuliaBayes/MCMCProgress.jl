"""
    Outcome

How a chain or a run ended: `finished`, `failed`, or `interrupted`. A chain that
is still running has the outcome `nothing`.
"""
@enum Outcome finished failed interrupted
