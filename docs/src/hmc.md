# Example: HMC

We'll demonstrate (some of) MCMCProgress with a basic [Hamiltonian Monte Carlo (HMC)](https://en.wikipedia.org/wiki/Hamiltonian_Monte_Carlo) sampler.

## Setup

To begin with, let's define the log-density that we want to sample from, and its gradient:

```@example hmc
logp(x) = -sum(abs2, x) / 2
∇logp(x) = -x
```

along with one step of the HMC algorithm:

```@example hmc
function hmc_step(x, step_size, n_leapfrog_steps)
    # Sample new momentum
    r = randn(length(x))

    # Simulate Hamiltonian dynamics via leapfrog integration
    x′, r′ = x, r + step_size / 2 * ∇logp(x)
    for l in 1:n_leapfrog_steps
        x′ = x′ + step_size * r′
        r′ = r′ + (l < n_leapfrog_steps ? step_size : step_size / 2) * ∇logp(x′)
    end

    # Metropolis accept/reject
    logα = logp(x′) - logp(x) - (sum(abs2, r′) - sum(abs2, r)) / 2
    return log(rand()) < logα ? (x′, true) : (x, false)
end
```

## How MCMCProgress works

Before we implement the actual sampling loop, it's worth describing how MCMCProgress works.

The central object in MCMCProgress is a [`RunProgress`](@ref) object, which tracks the overall status of some MCMC run.
You can initialise one by calling the [`progress`](@ref) function:

```@example hmc
using MCMCProgress

progress(; label="HMC", nchains=4, backend=PlainTextBackend()) do run
    @show typeof(run)
end
```

Our sampling loop will be placed inside this `do` block, and will send updates to `run` as it progresses.

Each `RunProgress` contains one or more [`ChainProgress`](@ref) objects, which track the progress of individual MCMC chains.
You can access a specific `ChainProgress` by calling the [`chain_at`](@ref) function:

```@example hmc
progress(; label="HMC", nchains=4, backend=PlainTextBackend()) do run
    @show num_chains(run)

    for i in 1:num_chains(run)
        @show chain_at(run, i)
    end
end
```

Equivalently, and perhaps more easily, you can iterate over all chains with the [`chains`](@ref) function.

Finally, each `ChainProgress` contains one or more `Phase` objects, which track the progress of individual phases of the MCMC algorithm (e.g. warmup, sampling, etc.).
In the above example, you can see that each chain is initialised with an empty `Vector{Phase}`.

We can add a new phase to a chain by calling the [`open_phase!`](@ref) function, update the progress of that phase by calling [`advance!`](@ref), and finally end it with [`close_phase!`](@ref).
MCMCProgress provides several different kinds of phases.
Here we'll use [`Determinate`](@ref), which refers to a phase with a known number of steps:

```@example hmc
progress(; label="HMC", nchains=4, backend=PlainTextBackend()) do run
    nsteps = 3
    for chn in chains(run)
        p = open_phase!(chn, "Warmup", Determinate(nsteps))
        for i in 1:nsteps
            sleep(0.1) # Mimic some computation.
            advance!(p, i)
        end
        close_phase!(p)
    end
end
```

The call to `advance!` here on every iteration can, in principle, lead to _many_ updates being logged if the phase has a large number of steps.
To avoid this, MCMCProgress performs some throttling such that logging only occurs at regular intervals.
To demonstrate this, we can remove the `sleep` call and run the same code again:

```@example hmc
progress(; label="HMC", nchains=4, backend=PlainTextBackend()) do run
    nsteps = 100
    for chn in chains(run)
        p = open_phase!(chn, "Warmup", Determinate(nsteps))
        for i in 1:nsteps
            advance!(p, i)
        end
        close_phase!(p)
    end
end
```

## HMC in action

And indeed, that's all you really need to know to start using MCMCProgress.
Here's the full example of the HMC sampling loop, annotated with comments.

```@example hmc
# Sample a single chain.
function sample(status, dim)
    # Initialise chain
    x, step_size = randn(dim), 1.0

    # A crude adaptation phase which attempts to tune the step size.
    n_warmup = 100
    p = open_phase!(status, "Warmup", Determinate(n_warmup))
    for i in 1:n_warmup
        x, accepted = hmc_step(x, step_size, 10)
        step_size *= accepted ? 1.02 : 0.98
        advance!(p, i)
        sleep(0.001)
    end
    close_phase!(p)

    # Perform sampling with the tuned step size
    n_samples = 100
    draws = Vector{Vector{Float64}}(undef, n_samples)
    p = open_phase!(status, "Sampling", Determinate(n_samples))
    for i in 1:n_samples
        x, _ = hmc_step(x, step_size, 10)
        draws[i] = x
        advance!(p, i)
        sleep(0.001)
    end
    close_phase!(p)

    return draws
end

nchains = 4
draws = progress(; label="HMC", nchains, backend=PlainTextBackend()) do run
    dim = 10
    tasks = [Threads.@spawn sample(chain_at(run, j), dim) for j in 1:nchains]
    fetch.(tasks)
end
nothing # hide
```

So far, we've only seen the default plain text backend.
MCMCProgress.jl also provides backends with Term.jl and ProgressLogging.jl.

For example, to use the Term.jl backend, you can do:

```julia
using Term # You need to load this.

progress(; backend=TermBackend(), other_kwargs...) do run
    # sample as before
end
```

These don't render well in built documentation, so we can't run it here, but here's a video of it:

```@raw html
<script src="https://asciinema.org/a/bLn2Bv8nJQncWrqF.js" id="asciicast-bLn2Bv8nJQncWrqF" async="true"></script>
```
