# Random-walk Metropolis for a standard normal target, with live acceptance.
# Run with the examples environment. No diagnostics package is required.
using MCMCProgress, Random

function metropolis_progress(; nchains=4, draws=10_000, backend=PlainTextBackend())
    counts = [(draws=0, accepted=0) for _ in 1:nchains]
    locks = [ReentrantLock() for _ in 1:nchains]
    diagnostics = () -> map(eachindex(counts)) do chain
        lock(locks[chain]) do
            n, accepted = counts[chain]
            return (draws=n, acceptance=n == 0 ? missing : accepted / n)
        end
    end
    progress(; label="Normal target", nchains, backend, diagnostics) do run
        @sync for chain in 1:nchains
            Threads.@spawn begin
                rng = Xoshiro(8675309 + chain)
                x, accepted = 0.0, 0
                phase = open_phase!(chain_at(run, chain), "Sampling", Determinate(draws))
                for n in 1:draws
                    y = x + randn(rng)
                    if 2log(rand(rng)) < x^2 - y^2
                        x = y
                        accepted += 1
                    end
                    lock(locks[chain]) do
                        counts[chain] = (draws=n, accepted=accepted)
                    end
                    advance!(phase, n)
                end
            end
        end
    end
end
