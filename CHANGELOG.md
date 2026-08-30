# Changelog

## Unreleased

### Removed (breaking, will be released as 2.0.0)

The experimental session-types layer moved out of this package into
[`pacta`](https://github.com/byzantine-systems/pacta). Eparch is now what its
description says and nothing more: type-safe wrappers over Erlang/OTP behaviours.

Modules removed:

- `eparch/session/core`
- `eparch/session/duality`
- `eparch/session/patterns`
- `eparch/protocol/spec`
- `eparch/protocol/graph`
- `eparch/protocol/relations`
- `eparch/protocol/weave`
- `eparch/protocol/emit`
- `eparch/protocol_machine`

They are available unchanged in `pacta`, under a `pacta/` prefix instead of
`eparch/`, so the migration is a rename at the import site:

```gleam
// before
import eparch/session/core.{type Channel}
import eparch/protocol_machine as pm

// after
import pacta/session/core.{type Channel}
import pacta/protocol_machine as pm
```

`eparch/state_machine` keeps the API `pacta/protocol_machine` was built on, so a
project using both continues to depend on this package directly.

Also removed alongside them: `docs/Session_Types.md` (now a `pacta` hexdocs page),
`examples/atm` (now `pacta`'s), and the `simplifile` / `argv` dev-dependencies,
which only the session-types generator driver used.

### Unchanged

`eparch/state_machine`, `eparch/event_manager` and `eparch/start_options`, along
with their three Erlang FFI modules, are untouched by this split.
