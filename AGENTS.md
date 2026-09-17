# Instructions for Agents

  - **Always** use a temporary environment with MCMCProgress dev'd into it to run code.
    This avoids adding deps into MCMCProgress itself.
    For example, Term and ProgressLogging are weak dependencies of MCMCProgress and should not be added to `[deps]`.

  - Sometimes you will need to add new dependencies. **ALWAYS DO THIS BY CALLING Pkg.jl**; do NOT
    edit the `Project.toml` manually as you will often insert the wrong UUID!

  - A backend supplied by an extension needs its package loaded first: `using Term` for `TermBackend`, `using ProgressLogging` for `ProgressLoggingBackend`.

  - When running `progress` outside the gallery, **always** pass `backend=PlainTextBackend(IOBuffer())` or `backend=MCMCProgress.RecordingBackend()`, so the display does not write to the REPL.

  - The locking rules for chains and phases are at the top of `src/phase.jl`.
    Read them before changing `Phase`, `Chain`, or any function that reads or writes their state.

# Overview

MCMCProgress displays the progress of MCMC chains, each moving through a sequence of phases.

The core package draws plain text and has no display dependencies.
Term and ProgressLogging support lives in package extensions under `ext/`.

`examples/` has its own `Project.toml`, with MCMCProgress as a path source.
Run the gallery with `julia --project=examples examples/gallery.jl --help`.

# Reporting progress

```
using MCMCProgress

progress(; label="Sampling mymodel", nchains=2) do run
    @sync for j in 1:2
        Threads.@spawn begin
            c = chain(run, j)
            p = open_phase!(c, "Warmup", Determinate(100))
            for i in 1:100
                advance!(p, i)
            end
            close_phase!(p)
        end
    end
end
```

  - `Determinate(total)`, `Counting()` and `Binary()` are the phase kinds.
  - `advance!` sets an absolute position and takes no lock.
  - `progress` closes any phase left open and gives every chain an outcome, however the body ends.

# Writing a backend

```
struct MyBackend end

MCMCProgress.setup(::MyBackend, snapshot::RunSnapshot) = handle
MCMCProgress.refresh(handle, snapshot::RunSnapshot) = nothing
MCMCProgress.teardown(handle, snapshot::RunSnapshot) = nothing
```

  - `phase_opened` and `phase_closed` are optional.
  - While the body of `progress` runs, only the refresh task calls a backend, so a backend needs no locking.
  - A backend whose methods live in an extension defines `backend_package`.

# Testing

```
backend = MCMCProgress.RecordingBackend()
MCMCProgress.display_run(body, "Sampling mymodel", nchains, backend, TEST_PERIOD)
```

  - `display_run` is `progress` with an explicit refresh period; `TEST_PERIOD` (20 ms, in `test/scope.jl`) keeps tests fast.
  - `backend.calls` lists every backend call in order.
