using MCMCProgress
using Documenter
using DocumenterCodeBlocks

makedocs(;
    sitename="MCMCProgress.jl",
    format=Documenter.HTML(),
    modules=[MCMCProgress],
    pages=[
        "index.md",
        "hmc.md",
        "api.md",
    ],
    checkdocs=:exports,
    warnonly=false,
    doctest=false,
    plugins=[CodeBlocks()],
)

Documenter.deploydocs(;
    repo="github.com/JuliaBayes/MCMCProgress.jl",
    target="build",
    push_preview=true,
)
