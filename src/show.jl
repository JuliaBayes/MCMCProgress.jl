# `show` methods for the snapshot types, so a run is inspectable at the REPL
# without a backend.

_position_text(p::PhaseSnapshot{Determinate}) = string(p.position, "/", p.kind.total)
_position_text(p::PhaseSnapshot{Counting}) = string(p.position)
_position_text(::PhaseSnapshot{Binary}) = nothing

function Base.show(io::IO, p::PhaseSnapshot)
    state = p.closed === nothing ? "open" : "closed"
    print(io, "PhaseSnapshot(", repr(p.name), ", ", p.kind, ", ", state)
    position = _position_text(p)
    position === nothing || print(io, ", ", position)
    print(io, ")")
end

function Base.show(io::IO, c::ChainSnapshot)
    print(io, "ChainSnapshot(", c.index, ", ", length(c.phases), " phase")
    length(c.phases) == 1 || print(io, "s")
    c.outcome === nothing || print(io, ", ", c.outcome)
    print(io, ")")
end

function Base.show(io::IO, r::RunSnapshot)
    print(io, "RunSnapshot(", repr(r.label), ", ", length(r.chains), " chain")
    length(r.chains) == 1 || print(io, "s")
    print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", r::RunSnapshot)
    print(io, "Run ", repr(r.label), " (", length(r.chains), " chain")
    length(r.chains) == 1 || print(io, "s")
    print(io, ")")
    for c in r.chains
        print(io, "\n  ")
        show(io, c)
        for p in c.phases
            print(io, "\n    ")
            show(io, p)
        end
    end
end
