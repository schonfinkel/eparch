# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`eparch` is a Gleam library (Erlang target only) that wraps Erlang/OTP behaviours in a type-safe API:

| Gleam module | Wraps | Erlang FFI module |
|---|---|---|
| `eparch/state_machine` | `gen_statem` | `src/statem_ffi.erl` |
| `eparch/event_manager` | `gen_event` | `src/event_manager_ffi.erl` |
| `eparch/start_options` | shared start-option types | `src/eparch_options_ffi.erl` |

The session-types layer that used to sit on top of these wrappers now lives in
[`pacta`](https://github.com/byzantine-systems/pacta), a separate package that depends on
this one. Nothing in this repository imports it, and nothing here may: eparch is the lower
layer, and an import in that direction would be a cycle between two published packages.

If a change here alters `state_machine`'s public API, it is a breaking change for pacta's
`protocol_machine`, which consumes `Action`, `Event`, `Builder`, `StartResult` and the
builder/action functions. That is a Hex release boundary, not a same-commit fix.

## Skills

Project-local skills live in `.agents/skills/<name>/SKILL.md`, most with deeper material under `references/` or `rules/` that the `SKILL.md` points at. Read the relevant one **before** writing code, and read the referenced file rather than the whole tree.

The ones that apply to work in this repo:

| Skill | Read it when |
|---|---|
| `gleam` | Writing any pure Gleam: library API design, shared domain types, parse-don't-validate, decoders. The default skill for `src/eparch/*.gleam`. |
| `erlang` | Touching the `_ffi.erl` files: BEAM concurrency, processes, links/monitors, selective receive. |
| `gleam-backend` | OTP actors and supervision trees specifically. `references/otp-advanced.md` is the relevant part; most of this skill is Wisp/Mist/SQL-codegen material that does not apply to a library. |
| `using-flake-parts` | Editing `flake.nix`, which is a flake-parts flake with the devenv and treefmt flake modules. |

The remaining skills (`api-gleam`, `nixos-best-practices`, `nix-module-options`, `nix-packaging-best-practices`) target REST services and NixOS system configuration and have no bearing on this codebase.

## Commands

Development environment is Nix + devenv (`nix develop`, or `direnv allow .` if using direnv).

```sh
gleam build                 # compile
gleam test                  # full gleeunit suite
gleam format                # required before opening a PR (see PR checklist)
gleam docs build            # render hexdocs, including docs/ + examples/ pages

nix fmt                     # treefmt: erlfmt + gleam format + nixfmt
nix flake check             # what CI runs first; fails on unformatted files
nix build                   # nix-gleam package build

make                        # builds + tests every project under examples/ (parallel)
```

Run a **single test** (gleeunit has no filtering flag, so go through EUnit directly):

```sh
gleam build
erl -pa build/dev/erlang/*/ebin -noshell \
  -eval 'eunit:test({test, actions_test, stop_normal_terminates_process_test}, [verbose]), halt().'
# whole module: {module, actions_test}
```

CI (`.github/workflows/build.yml`) runs: `nix flake check` → `nix build` → `gleam test` → `make`.

## Architecture

### Gleam ⇄ Erlang encoding contract

The Gleam modules are almost entirely type declarations plus `@external` stubs; all behaviour lives in the `_ffi.erl` files. The two sides communicate through Gleam's *implicit* runtime representation of custom types (constructor name lowercased into an atom, fields positional), which the Erlang code pattern-matches literally:

- `Builder(...)` in `state_machine.gleam` is destructured in `statem_ffi:unpack_builder/1` as a 12-tuple `{builder, InitialState, InitialData, Handler, ...}`.
- `StartOptions(...)` in `event_manager.gleam` is destructured as `{start_options, NameOpt, Timeout, HibernateAfter, DebugFlags, SpawnOpts}`.
- `Handler(...)`, `Status(...)`, `Event`, `Step`, `Action`, `Timeout`, `DebugFlag`, `SpawnOption` etc. are all matched/emitted by name in Erlang.
- `Option` arrives as `none | {some, V}`; `Result` as `{ok, V} | {error, E}`; `process.ExitReason` as `{normal} | {killed} | {abnormal, T}`.

**Consequence:** renaming a constructor, reordering record fields, or adding a field to any of these types silently breaks the FFI at runtime with no compiler error. Every such change must be mirrored in the matching Erlang clause, and `ServerName` variants are deliberately shaped as `{local, _} | {global, _} | {via, _, _}` so they can be handed straight to OTP.

### Phantom / external types

`ServerRef(message)`, `From(reply)`, `RequestId(reply)`, `RequestIdCollection(label, reply)`, `HandlerRef(request, reply)`, `Manager(event)`, and `SwapTerm` are declared in Gleam with no constructors. Their values only ever originate from Erlang (a Pid, a `{server_ref_subject, Subject}` tuple, a `gen_event` handler id, …). The type parameters exist purely to make mismatched message/reply/request types a compile error on the caller side; nothing checks them at runtime, so FFI functions producing them must be correct by construction.

### `state_machine` specifics

- `callback_mode/0` **always** returns `[handle_event_function, state_enter]` because OTP calls it before `init/1`. Opting out via the builder is enforced by a guard clause in `handle_event/4` that drops `enter` events when `state_enter = state_enter_disabled`.
- `init/1` builds the `ServerRef` **and** a `subject_tag`, then hands the ref to the parent over a `make_ref()` ack channel before `gen_statem:start*` returns. The tag is the `Subject` tag for unnamed/`Local` servers, and a throwaway ref for `Global`/`Via` (which have no `Subject`, hence `ref_to_subject` returns `Error(Nil)` for them).
- Info events are unwrapped against `subject_tag`: `{Tag, Msg}` (i.e. sent via `process.send`) becomes `Info(Msg)`; anything else passes through raw as `Info(Term)`. The same unwrapping is duplicated in `format_status`'s queue classification, so keep them in sync.
- `internal` events (from the `NextEvent` action) are surfaced to Gleam as `Cast(msg)`, not a distinct variant.
- `format_status/1` uses `maps:map/2` over the incoming status map so optional OTP keys absent from the input stay absent from the output. `classify_*`/`unclassify_*` pairs must round-trip; every classifier has an `*_other`/`raw_*` fallback so an unrecognised OTP shape can never crash the callback.

### `event_manager` specifics

`event_manager_ffi` is both the API layer and the `gen_event` callback module. Each Gleam handler is installed as `{event_manager_ffi, Ref}` with a fresh `make_ref()`, which is what a `HandlerRef` actually is. That's how multiple instances of "the same" handler stay distinguishable. Handler state is a `#gleam_handler{}` record holding the user's Gleam state plus the optional callbacks. In the swap path, `on_swap_out` runs **instead of** `on_terminate`.

### OTP version floors

Several APIs are OTP-gated and say so in their doc comments (`start_monitor` OTP 23, `receive_response` OTP 24, the whole reqids collection API OTP 25, timeout cancel/update actions OTP 22.1, callback-module actions OTP 22.3). Keep new wrappers annotated the same way.

## Tests

`test/*_test.gleam`, gleeunit conventions (any `pub fn *_test()` is collected), assertions via the `assert` keyword. Do not reach for `gleeunit/should`; it is deprecated in gleeunit itself ("Use the `assert` keyword instead of this module"). Tests are integration-style: they start real processes and assert through monitors, selectors, and `sys:get_status/1` rather than unit-testing pure functions. Each section in a file declares its own state/msg types with a section-specific constructor prefix to avoid collisions. `test/eparch_test_helpers.erl` exists to build Erlang-shaped values Gleam cannot express (e.g. a raw `{global, Name}` target); add to it rather than reaching for `dynamic` casts.


## Examples

`examples/*` are standalone Gleam projects depending on `eparch = { path = "../../" }`, each with its own tests, listed in `examples/README.md` and shipped as a hexdocs page via `gleam.toml`'s `[documentation]` section. A public API change usually means updating them; `make` is what CI uses to check.

## Conventions

- Commits follow Conventional Commits (`feat:`, `fix:`, `refactor:`, `ci:`, `hex:`).
- Public Gleam functions and types carry doc comments with a `## Example` block; module headers use `////`. Erlang FFI functions use `-doc """..."""` and `-moduledoc`. This documentation is the package's hexdocs, so it is not optional.
- Erlang is formatted by `erlfmt` via treefmt; unformatted files fail `nix flake check`.
