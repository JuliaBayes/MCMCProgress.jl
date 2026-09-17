# Instructions for Agents

  - Function names are snake_case (`open_phase!`, `set_backend!`).
  - A struct, the functions that work on it, its snapshot type, and the snapshot's `show` methods live in the same file.
  - Tests of a whole run call `MCMCProgress.display_run` with `TEST_PERIOD` (defined in `test/scope.jl`) rather than `progress`, so refreshes come every 20 ms instead of every 100 ms.
    `MCMCProgress.RecordingBackend` records every backend call, so a test can check what a backend was told.

# Layout

  - `src/phase.jl`, `src/chain.jl`, `src/run.jl`: the live state (`Phase`, `Chain`, `Run`), the reporting functions, and the snapshot types.
  - `src/scope.jl`: `progress`, the refresh task, and the teardown.
  - `src/backends.jl`: the backend interface and backend selection.
  - `src/plaintext.jl`: the default backend.
    `src/term.jl` and `src/progresslogging.jl` define backend types whose methods are in `ext/`.
  - `examples/gallery.jl`: a runnable demo of each phase kind, run ending and backend.
    Run `julia --project=examples examples/gallery.jl --help`.

# Concurrency

  - The locking rules for chains and phases are at the top of `src/phase.jl`.
    Read them before changing `Phase`, `Chain`, or any function that reads or writes their state.
  - While the body of `progress` runs, only the refresh task calls a backend (see the header of `src/scope.jl`).
    A backend therefore needs no locking.

# Writing a backend

  - Implement `setup`, `refresh` and `teardown`; `phase_opened` and `phase_closed` are optional.
    `setup` returns a handle, and every other call receives that handle.
  - A backend whose methods live in a package extension defines `backend_package`, so selecting it before the package is loaded throws an error naming the package.
