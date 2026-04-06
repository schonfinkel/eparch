# Quick Start

## State Machine

The `eparch/state_machine` module wraps `gen_statem` with a type-safe API. Define your states, messages, and a single event handler, then wire it up with a builder:

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

## Event Manager

Create a manager, attach handlers, and broadcast events:

```gleam
import eparch/event_manager
import gleam/erlang/process

type LogEvent { LogLine(String) | Flush(process.Subject(Nil)) }

pub fn main() {
  let assert Ok(mgr) = event_manager.start()

  let handler =
    event_manager.new_handler(initial_state: 0, on_event: fn(event, count) {
      case event {
        LogLine(_) -> event_manager.Continue(count + 1)
        Flush(reply) -> {
          process.send(reply, Nil)
          event_manager.Continue(count)
        }
      }
    })

  let assert Ok(_ref) = event_manager.add_handler(mgr, handler)

  event_manager.notify(mgr, LogLine("hello"))      // async
  event_manager.sync_notify(mgr, LogLine("world")) // blocks until processed
}
```
