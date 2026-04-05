# Eparch

[![Package Version](https://img.shields.io/hexpm/v/eparch)](https://hex.pm/packages/eparch)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/eparch/)
![License](https://img.shields.io/github/license/schonfinkel/eparch)

[![Built with Nix](https://builtwithnix.org/badge.svg)](https://builtwithnix.org)
[![[Nix] Build & Test](https://github.com/schonfinkel/eparch/actions/workflows/build.yml/badge.svg)](https://github.com/schonfinkel/eparch/actions/workflows/build.yml)

> **EPARCH OF THE CITY (ἔπαρχος τῆς πόλεως)**, successor of the late Roman URBAN PREFECT, the governor of Constantinople. [^1]
>
> [^1]: The Oxford Dictionary of Byzantium, Vol II.

Eparch is a library that brings type-safe wrappers for some Erlang/OTP behaviours, making your [byzantine systems](https://en.wikipedia.org/wiki/Byzantine_fault) shine with Gleam's type system.

## Supported OTP Behaviours

- [x] [`gen_statem`](https://www.erlang.org/doc/apps/stdlib/gen_statem.html): OTP's newest behaviour for finite state machines.
- [ ] [`gen_event`](https://www.erlang.org/doc/apps/stdlib/gen_event.html): For creating event managers.

## Installation

```sh
gleam add eparch
```

## Quick Start

The `eparch/state_machine` module wraps `gen_statem` with a type-safe API. You must define your states and messages as custom Gleam types, write a single event handler, and wire everything up with a `Builder`:

```gleam
import eparch/state_machine as sm
import gleam/erlang/process

type State { Off | On }

type Msg {
  Push
  GetCount(reply_with: process.Subject(Int))
}

fn handle_event(event, state, data: Int) {
  case event, state {
    sm.Info(Push), Off -> sm.next_state(On, data + 1, [])
    sm.Info(Push), On  -> sm.next_state(Off, data, [])

    sm.Info(GetCount(reply_with: subj)), _ -> {
      process.send(subj, data)
      sm.keep_state(data, [])
    }

    _, _ -> sm.keep_state(data, [])
  }
}

pub fn start() {
  let assert Ok(machine) =
    sm.new(initial_state: Off, initial_data: 0)
    |> sm.on_event(handle_event)
    |> sm.start

  machine.data  // Subject(Msg)
}
```

### Synchronous calls via `gen_statem:call`

For request/reply without embedding a `Subject` in the message, use the native `gen_statem` call mechanism, events arrive as `sm.Call(from, msg)` and replies are sent back with `sm.Reply`:

```gleam
import eparch/state_machine as sm

type Msg { Unlock(String) }

fn handle_event(event, state, data) {
  case event, state {
    sm.Call(from, Unlock(entered)), Locked ->
      case entered == data.code {
        True  -> sm.next_state(Open, data, [sm.Reply(from, Ok(Nil))])
        False -> sm.keep_state(data, [sm.Reply(from, Error("Wrong code"))])
      }
    _, _ -> sm.keep_state(data, [])
  }
}
```

### State Enter callbacks

You can also opt into `state_enter` to react whenever the machine enters a new state:

```gleam
sm.new(initial_state: Locked, initial_data: data)
|> sm.with_state_enter()
|> sm.on_event(handle_event)
|> sm.start

// In handle_event, auto-lock after 5 s when entering "Open"
fn handle_event(event, state, data) {
  case event, state {
    // ...
    sm.Enter(_), Open -> sm.keep_state(data, [sm.StateTimeout(5000)])
    // ...
  }
}
```

### Key differences from `gen_statem`

| Erlang `gen_statem` | `eparch/state_machine` |
|---|---|
| Separate `handle_call`, `handle_cast`, `handle_info` | Single `handle_event` dispatching on `Event` |
| Raw action tuples | Type-safe `Action` values |
| `state_enter` always on | Opt-in via `with_state_enter()` |
| Multiple return tuple formats | Single `Step` type |

Full API reference: <https://hexdocs.pm/eparch>

## Development

The project uses [devenv](https://devenv.sh/) and [Nix](https://nixos.org/) for
a hermetic development environment:

```sh
nix develop
```

Or, if you are already using [direnv](https://direnv.net/):

```sh
direnv allow .
```
