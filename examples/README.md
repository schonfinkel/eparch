# Examples

Runnable example projects for the `eparch` library. Each example is a self-contained Gleam project with unit / integration tests.

```sh
cd examples/<example>
gleam test
```

## State Machine (`gen_statem`)

| Example | Description |
|---|---|
| [`push-button`](https://github.com/schonfinkel/eparch/tree/main/examples/push-button) | Basic state transitions, synchronous calls, press counter |
| [`simple-door-lock`](https://github.com/schonfinkel/eparch/tree/main/examples/simple-door-lock) | Shows how to use `with_state_enter`, `StateTimeout` for auto-lock, wrong-code tracking |

### Push-Button

The canonical OTP `gen_statem` [example from the official docs](https://www.erlang.org/doc/apps/stdlib/gen_statem.html#module-pushbutton-state-diagram). 

- A button toggles between `Off` and `On`.
- Only `Off -> On` transitions increment the press counter.

### Door Lock

A code-protected door lock. Also an example from the [docs](https://www.erlang.org/doc/system/statem.html#example).

- Entering the correct code opens the lock. 
- The door auto-relocks after a configurable timeout via `StateTimeout`.
- Demonstrates `with_state_enter` to arm the timer on every entry to the `Open` state.

## Event Handler (`gen_event`)

| Example | Description |
|---|---|
| [`terminal-logger`](https://github.com/schonfinkel/eparch/tree/main/examples/terminal-logger) | Fan-out broadcasting via `notify`, multiple handlers with independent state, `on_terminate` cleanup |

### Terminal Logger

A pair of `gen_event` handlers wired to a single event bus. Modelled after the canonical [`error_man` example from the OTP docs](https://www.erlang.org/doc/system/events.html).

- `add_terminal_logger`: prints each event to stdout and tracks a count
- `add_file_logger`: appends each event to a file path
- `report` broadcasts to every registered handler in one call

## Session Types (`eparch/session`, `eparch/protocol`)

| Example | Description |
|---|---|
| [`atm`](https://github.com/schonfinkel/eparch/tree/main/examples/atm) | A protocol specification, projected onto both participants, generated into typed positions, and driven from a `gen_statem` |

### ATM

The ATM protocol from Laumann, Munksgaard and Larsen, [*Session Types for Rust*](https://munksgaard.me/papers/laumann-munksgaard-larsen.pdf).

- One global specification, projected onto a `Client` and an `Atm`.
- Recursion, so it is a protocol that **cannot** be written as a nested Gleam type at all: the generator flattens it into named positions with an edge back to the head of the loop.
- The machine side as a `protocol_machine`, the client side walked by hand, both checked against the same specification.
- Duality and subtyping decided over the projected graphs, including the answer to the "can I add a branch without breaking everyone" question the paper raises and leaves to the reader.
- Generated modules committed, with `gleam run -m generate check` to fail CI when they go stale.
