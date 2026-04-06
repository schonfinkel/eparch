////
//// Door lock example for `eparch/state_machine`.
////
//// Demonstrates:
//// - `with_state_enter()` to trigger an action on entering a state
//// - `StateTimeout` to auto-lock after a configurable delay
//// - Synchronous replies using embedded `Subject` in messages
////
//// ## Usage
////
//// ```gleam
//// import doorlock
////
//// pub fn main() {
////   let assert Ok(machine) = doorlock.start("1234")
////   let subject = machine.data
////
////   doorlock.get_status(subject)   // => Locked
////   doorlock.enter_code(subject, "0000")  // => Error("Wrong code")
////   doorlock.enter_code(subject, "1234")  // => Ok(Nil) — now Open
////   doorlock.get_status(subject)   // => Open
////   // After 5 seconds the door auto-locks back to Locked
//// }
//// ```

import eparch/state_machine as sm
import gleam/erlang/process

// Public types
pub type State {
  Locked
  Open
}

pub type Data {
  Data(code: String, attempts: Int)
}

pub type Message {
  /// Attempt to unlock. Embeds a reply Subject so the caller gets back
  /// `Ok(Nil)` on success or `Error("Wrong code")` on failure.
  EnterCode(code: String, reply_with: process.Subject(Result(Nil, String)))

  /// Query the current state without changing it.
  GetStatus(reply_with: process.Subject(State))
}

// Public API
/// Start the door lock with a 5-second auto-lock timeout.
pub fn start(
  code: String,
) -> Result(sm.Started(process.Subject(Message)), sm.StartError) {
  start_with_lock_timeout(code, 5000)
}

/// Start the door lock with a configurable auto-lock timeout.
///
/// Prefer `start/1` in production; use this in tests to keep timeouts short.
pub fn start_with_lock_timeout(
  code: String,
  auto_lock_ms: Int,
) -> Result(sm.Started(process.Subject(Message)), sm.StartError) {
  sm.new(Locked, Data(code, 0))
  |> sm.on_event(fn(event, state, data) {
    handle_event(auto_lock_ms, event, state, data)
  })
  |> sm.with_state_enter()
  |> sm.start
}

/// Send a code to the lock and wait for the result.
pub fn enter_code(
  subject: process.Subject(Message),
  code: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply) { EnterCode(code, reply) })
}

/// Query the current lock state synchronously.
pub fn get_status(subject: process.Subject(Message)) -> State {
  process.call(subject, 5000, GetStatus)
}

// Event handler
/// Handle state machine events.
///
/// Exported so unit tests can exercise it directly without spawning a process.
pub fn handle_event(
  auto_lock_ms: Int,
  event: sm.Event(State, Message, Nil),
  state: State,
  data: Data,
) -> sm.Step(State, Data, Message, Nil) {
  case event, state {
    // On entering the Open state, arm the auto-lock timer.
    sm.Enter(_), Open -> sm.keep_state(data, [sm.StateTimeout(auto_lock_ms)])

    // Correct code while Locked -> unlock.
    sm.Info(EnterCode(entered, reply_sub)), Locked if entered == data.code -> {
      process.send(reply_sub, Ok(Nil))
      sm.next_state(Open, data, [])
    }

    // Wrong code while Locked -> stay locked, count the attempt.
    sm.Info(EnterCode(_, reply_sub)), Locked -> {
      process.send(reply_sub, Error("Wrong code"))
      sm.keep_state(Data(..data, attempts: data.attempts + 1), [])
    }

    // Entering a code while already Open -> acknowledge without state change.
    sm.Info(EnterCode(_, reply_sub)), Open -> {
      process.send(reply_sub, Ok(Nil))
      sm.keep_state(data, [])
    }

    // State timeout fired -> re-lock.
    sm.Timeout(sm.StateTimeoutType), Open -> sm.next_state(Locked, data, [])

    // Status query in any state -> reply with current state.
    sm.Info(GetStatus(reply_sub)), _ -> {
      process.send(reply_sub, state)
      sm.keep_state(data, [])
    }

    // Everything else (unmatched Enter events, casts, etc.) -> no-op.
    _, _ -> sm.keep_state(data, [])
  }
}
