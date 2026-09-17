"""
    TermBackend(columns=nothing; columns_kwargs=Dict{Symbol,Any}())

A backend that draws one progress bar per chain with
[Term.jl](https://github.com/FedeClaudi/Term.jl)'s `ProgressBar`, each bar
showing the phase its chain is in. Requires `using Term`.

`columns` chooses the Term columns each bar is built from. With `nothing`, the
default is a description, the bar, the position and percentage for a
determinate phase, and an estimate of the time remaining, with no column for
elapsed time. A `Vector` of Term column types, or one of Term's preset symbols
such as `:minimal`, is passed to `ProgressBar` as given. `columns_kwargs` passes
keyword arguments to individual columns, keyed by column type name, as
`Term.Progress.ProgressBar` accepts them.
"""
struct TermBackend{C}
    columns::C
    columns_kwargs::Dict{Symbol,Any}

    TermBackend{C}(columns, columns_kwargs) where {C} = new{C}(columns, columns_kwargs)
end

TermBackend(columns=nothing; columns_kwargs::Dict{Symbol,Any}=Dict{Symbol,Any}()) =
    TermBackend{typeof(columns)}(columns, columns_kwargs)

backend_package(::TermBackend) = "Term"
