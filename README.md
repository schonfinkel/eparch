# Eparch

[![Package Version](https://img.shields.io/hexpm/v/eparch)](https://hex.pm/packages/eparch)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/eparch/)
![License](https://img.shields.io/github/license/schonfinkel/eparch)

[![Built with Nix](https://builtwithnix.org/badge.svg)](https://builtwithnix.org)
[![[Nix] Build & Test](https://github.com/schonfinkel/eparch/actions/workflows/build.yml/badge.svg)](https://github.com/schonfinkel/eparch/actions/workflows/build.yml)

> **EPARCH OF THE CITY (ἔπαρχος τῆς πόλεως)**, successor of the late Roman URBAN PREFECT, the governor of Constantinople. [^1]
>
> [^1]: The Oxford Dictionary of Byzantium, Vol II.

Eparch is a Gleam library that wraps certain Erlang/OTP behaviours with a type-safe API, making your [byzantine systems](https://en.wikipedia.org/wiki/Byzantine_fault) shine with a great type system.

## Supported OTP Behaviours

| Module | Wraps | Purpose |
|---|---|---|
| `eparch/state_machine` | [`gen_statem`](https://www.erlang.org/doc/apps/stdlib/gen_statem.html) | Type-safe finite state machines |
| `eparch/event_manager` | [`gen_event`](https://www.erlang.org/doc/apps/stdlib/gen_event.html) | Broadcast event managers with dynamic handlers |

Full API reference: <https://hexdocs.pm/eparch>.

### Key Differences from `gen_statem`

| Erlang's `gen_statem` | `eparch/state_machine` |
|---|---|
| Separate `handle_call`, `handle_cast`, `handle_info` | Single handler dispatching on a unified `Event` type |
| Raw action tuples | Type-safe `Action` values |
| `state_enter` always on | Opt-in via `with_state_enter()` |
| Multiple return tuple formats | Single `Step` type (`NextState`, `KeepState`, `Stop`) |

### Key Differences from `gen_event`

| Erlang's `gen_event` | `eparch/event_manager` |
|---|---|
| Separate handler callback module per handler | Single `Handler` builder (`new_handler/2`, `on_terminate/2`) |
| Handler identified by `{Module, Id}` tuple | Opaque `HandlerRef` returned by `add_handler` |
| `handle_call` for per-handler queries | Embed `process.Subject(reply)` in your event type instead |
| `add_sup_handler` | `add_supervised_handler` |

## Installation

```sh
gleam add eparch
```

### Usage

See the [Quick Start guide](https://hexdocs.pm/eparch/quick_start.html) for full walkthroughs, or run some of the example projects that live in the [`examples/`](https://hexdocs.pm/eparch/readme.html) directory.

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
