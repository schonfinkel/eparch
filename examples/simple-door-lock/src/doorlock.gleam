import eparch/state_machine as sm
import gleam/list

// Types
pub type State {
  Locked
  Open
}

pub type Data {
  Data(code: List(Int), remaining: List(Int))
}

pub type Message {
  /// A single keypad button press. Delivered as a `Cast`
  /// (fire-and-forget) since the caller does not wait for a reply.
  Button(digit: Int)

  /// Synchronous query for the current lock state.
  GetStatus

  /// Payload delivered when the auto-lock timer fires.
  AutoLock
}

/// Replies are unified into one type because `gen_statem` uses a single
/// reply channel per machine.
pub type Reply {
  StatusReply(state: State)
}

/// Handle state machine events.
///
/// Exported so unit tests can exercise it directly without spawning a process.
pub fn handle_event(
  auto_lock_ms: Int,
  event: sm.Event(State, Message, Reply),
  state: State,
  data: Data,
) -> sm.Step(State, Data, Message, Reply) {
  case event, state {
    // On entering Locked, reset the digit buffer to the full code.
    sm.Enter(_), Locked -> sm.keep_state(Data(..data, remaining: data.code), [])

    // On entering Open, arm the auto-lock timer.
    sm.Enter(_), Open ->
      sm.keep_state_and_data([
        sm.state_timeout(sm.After(auto_lock_ms), AutoLock),
      ])

    // Button press while Locked: match against the next expected digit.
    sm.Cast(Button(digit)), Locked -> match_digit(digit, data)

    // Button presses while Open are ignored.
    sm.Cast(Button(_)), Open -> sm.keep_state_and_data([])

    // Auto-lock fires -> re-lock.
    sm.Timeout(sm.StateTimeoutType, AutoLock), Open ->
      sm.next_state(Locked, data, [])

    // GetStatus in any state -> reply with current state.
    sm.Call(from, GetStatus), _ ->
      sm.reply_and_keep(from, StatusReply(state), data)

    // Catch-all (unmatched Enter, stray timeouts, info, etc.) -> no-op.
    _, _ -> sm.keep_state_and_data([])
  }
}

/// Match an incoming digit against the next expected digit in `remaining`.
fn match_digit(digit: Int, data: Data) -> sm.Step(State, Data, Message, Reply) {
  case data.remaining {
    // Last digit matches -> unlock.
    [d] if d == digit ->
      sm.next_state(Open, Data(..data, remaining: data.code), [])

    // Prefix matches -> consume the digit, wait for more.
    [d, ..rest] if d == digit -> sm.keep_state(Data(..data, remaining: rest), [])

    // Wrong digit -> reset the buffer and stay locked.
    _ -> sm.keep_state(Data(..data, remaining: data.code), [])
  }
}

// Public API
/// Start the door lock with a 5-second auto-lock timeout.
pub fn start(code: List(Int)) -> sm.StartResult(Message) {
  start_with_lock_timeout(code, 5000)
}

/// Start the door lock with a configurable auto-lock timeout.
///
/// Prefer `start/1` in production; use this in tests to keep timeouts short.
pub fn start_with_lock_timeout(
  code: List(Int),
  auto_lock_ms: Int,
) -> sm.StartResult(Message) {
  sm.new(initial_state: Locked, initial_data: Data(code: code, remaining: code))
  |> sm.on_event(fn(event, state, data) {
    handle_event(auto_lock_ms, event, state, data)
  })
  |> sm.with_state_enter()
  |> sm.start
}

/// Press one button on the keypad. Fire-and-forget: the call returns
/// immediately and the lock processes the digit asynchronously.
pub fn button(ref: sm.ServerRef(Message), digit: Int) -> Nil {
  sm.cast(ref, Button(digit))
}

/// Press a sequence of buttons in order. Convenience over `button/2`.
pub fn enter_code(ref: sm.ServerRef(Message), digits: List(Int)) -> Nil {
  list.each(digits, fn(d) { button(ref, d) })
}

/// Query the current lock state synchronously.
pub fn get_status(ref: sm.ServerRef(Message)) -> State {
  let request: sm.RequestId(Reply) = sm.send_request(ref, GetStatus)
  let assert Ok(StatusReply(state)) = sm.receive_response(request, 5000)
  state
}
