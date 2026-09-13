"""
    TermBackend(columns=nothing; columns_kwargs=Dict{Symbol,Any}())

A backend that draws one progress bar per phase with
[Term.jl](https://github.com/FedeClaudi/Term.jl)'s own `ProgressBar`. Needs the
Term extension loaded: run `using Term` before this backend is selected.

`columns` chooses which of Term's columns each phase's bar is built from. Left
at `nothing`, the extension substitutes its own default list: a description,
the bar itself, the position and percentage for a determinate phase, and an
estimate of the time remaining — but no column for elapsed time, which the
extension's own documentation explains. Passing a `Vector` of Term column
types picks exactly those columns instead, and passing one of Term's own
preset symbols (such as `:minimal`) is handed to `ProgressBar` unchanged.
`columns_kwargs` carries keyword arguments through to individual columns,
keyed by column type name, exactly as `Term.Progress.ProgressBar` itself
accepts.

The core holds this configuration without knowing what a column is; the
extension is what turns it into an actual `Term.Progress.ProgressBar`.
"""
struct TermBackend{C}
    columns::C
    columns_kwargs::Dict{Symbol,Any}

    TermBackend{C}(columns, columns_kwargs) where {C} = new{C}(columns, columns_kwargs)
end

TermBackend(columns=nothing; columns_kwargs::Dict{Symbol,Any}=Dict{Symbol,Any}()) =
    TermBackend{typeof(columns)}(columns, columns_kwargs)

backend_package(::TermBackend) = "Term"
