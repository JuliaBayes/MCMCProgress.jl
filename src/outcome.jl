"""
    Outcome

How a chain or a run ended: `finished`, `failed`, or `interrupted`. A chain that
is still running has no outcome yet, spelled `nothing`.
"""
@enum Outcome finished failed interrupted
