////
//// Pushbutton example for `eparch/state_machine`.
////
//// Modelled after the canonical `gen_statem` pushbutton from the OTP docs.
////
//// Each call to `push` toggles the button between `Off` and `On`.
//// Only `Off -> On` transitions increment the press counter.
//// `get_count` queries the current count without changing state.
////
//// ## Usage
////
//// ```gleam
//// import pushbutton
////
//// pub fn main() {
////   let assert Ok(machine) = pushbutton.start()
////
////   pushbutton.get_count(machine.data)  // => 0
////   pushbutton.push(machine.data)       // => 0 (count before increment)
////   pushbutton.get_count(machine.data)  // => 1
////   pushbutton.push(machine.data)       // => 1 (On -> Off, no increment)
////   pushbutton.get_count(machine.data)  // => 1
//// }
//// ```

import eparch/state_machine as sm
import gleam/erlang/process

// Types

pub type State {
  Off
  On
}

/// Both messages are synchronous calls, the caller receives a reply.
pub type Msg {
  /// Toggle the button.
  /// `Off -> On` increments the count, reply is the count *before* the toggle.
  /// `On -> Off` does not increment, reply is the current count.
  Push

  /// Query the press count without changing state.
  GetCount
}

// API
/// Start the pushbutton with press count at 0 and initial state Off.
pub fn start() -> Result(sm.Started(process.Subject(Msg)), sm.StartError) {
  sm.new(Off, 0)
  |> sm.on_event(handle_event)
  |> sm.start
}

// Event Handler
/// Handle state machine events.
///
/// Exported so unit tests can exercise the handler directly without
/// spawning a process.
pub fn handle_event(
  event: sm.Event(State, Msg, Int),
  state: State,
  data: Int,
) -> sm.Step(State, Int, Msg, Int) {
  case event, state {
    // Off + Push -> On. 
    // - Count increments
    // - Reply is the count *before* the change
    sm.Call(from, Push), Off ->
      sm.NextState(On, data + 1, [sm.Reply(from, data)])

    // On + Push -> Off. 
    // - Count is unchanged.
    // - Reply is the current count
    sm.Call(from, Push), On -> sm.NextState(Off, data, [sm.Reply(from, data)])

    // GetCount is valid in any state
    // reply with count without changing state.
    sm.Call(from, GetCount), _ -> sm.KeepState(data, [sm.Reply(from, data)])

    // Any other event (casts, info, timeouts) is silently ignored.
    _, _ -> sm.KeepState(data, [])
  }
}
