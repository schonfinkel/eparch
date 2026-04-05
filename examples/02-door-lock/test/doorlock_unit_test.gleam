////
//// Unit tests for the door lock event handler.
////
//// These tests call `handle_event` directly without spawning a process,
//// so they run fast and are deterministic. The reply subjects created
//// with `process.new_subject()` let us verify that the handler sends the
//// expected reply as a side-effect before returning its Step.
////

import gleam/erlang/process
import gleeunit/should
import doorlock
import eparch/state_machine as sm

// Constants & Helpers
const code = "1234"

const data = doorlock.Data(code: "1234", attempts: 0)

const timeout_ms = 5000

fn call(event, state) {
  doorlock.handle_event(timeout_ms, event, state, data)
}

// EnterCode (Locked State)
/// Correct code while Locked transitions to Open with no actions.
/// The caller receives Ok(Nil) as a side-effect reply.
pub fn enter_correct_code_transitions_to_open_test() {
  let reply_sub = process.new_subject()

  call(sm.Info(doorlock.EnterCode(code, reply_sub)), doorlock.Locked)
  |> should.equal(sm.NextState(doorlock.Open, data, []))

  process.receive(reply_sub, 0)
  |> should.equal(Ok(Ok(Nil)))
}

/// Wrong code while Locked keeps the state and increments the attempt counter.
/// The caller receives Error("Wrong code").
pub fn enter_wrong_code_increments_attempts_test() {
  let reply_sub = process.new_subject()
  let expected_data = doorlock.Data(..data, attempts: 1)

  call(sm.Info(doorlock.EnterCode("0000", reply_sub)), doorlock.Locked)
  |> should.equal(sm.KeepState(expected_data, []))

  process.receive(reply_sub, 0)
  |> should.equal(Ok(Error("Wrong code")))
}

/// Repeated wrong codes accumulate in the attempt counter.
pub fn multiple_wrong_codes_accumulate_attempts_test() {
  let reply_sub = process.new_subject()

  let step1 =
    doorlock.handle_event(
      timeout_ms,
      sm.Info(doorlock.EnterCode("bad", reply_sub)),
      doorlock.Locked,
      data,
    )
  let assert sm.KeepState(data1, []) = step1

  let step2 =
    doorlock.handle_event(
      timeout_ms,
      sm.Info(doorlock.EnterCode("also_bad", reply_sub)),
      doorlock.Locked,
      data1,
    )
  let assert sm.KeepState(data2, []) = step2

  data2.attempts |> should.equal(2)
}

// EnterCode (Open State)
/// Entering a code while already Open acknowledges with Ok(Nil) and keeps state.
/// This avoids a process.call timeout when the caller doesn't know the door is open.
pub fn enter_code_while_open_keeps_state_test() {
  let reply_sub = process.new_subject()

  call(sm.Info(doorlock.EnterCode(code, reply_sub)), doorlock.Open)
  |> should.equal(sm.KeepState(data, []))

  process.receive(reply_sub, 0)
  |> should.equal(Ok(Ok(Nil)))
}

// State Enter
/// Entering the Open state arms the auto-lock timer.
pub fn entering_open_state_sets_timeout_test() {
  call(sm.Enter(doorlock.Locked), doorlock.Open)
  |> should.equal(sm.KeepState(data, [sm.StateTimeout(timeout_ms)]))
}

/// Entering the Locked state does nothing (no timer needed).
pub fn entering_locked_state_is_noop_test() {
  call(sm.Enter(doorlock.Open), doorlock.Locked)
  |> should.equal(sm.KeepState(data, []))
}

// State Timeout
/// When the state timeout fires while Open, the door re-locks.
pub fn state_timeout_while_open_transitions_to_locked_test() {
  call(sm.Timeout(sm.StateTimeoutType), doorlock.Open)
  |> should.equal(sm.NextState(doorlock.Locked, data, []))
}

/// A state timeout while already Locked is a no-op (catch-all branch).
pub fn state_timeout_while_locked_is_noop_test() {
  call(sm.Timeout(sm.StateTimeoutType), doorlock.Locked)
  |> should.equal(sm.KeepState(data, []))
}

// GetStatus
/// GetStatus while Locked replies with Locked and keeps state.
pub fn get_status_while_locked_test() {
  let reply_sub = process.new_subject()

  call(sm.Info(doorlock.GetStatus(reply_sub)), doorlock.Locked)
  |> should.equal(sm.KeepState(data, []))

  process.receive(reply_sub, 0)
  |> should.equal(Ok(doorlock.Locked))
}

/// GetStatus while Open replies with Open and keeps state.
pub fn get_status_while_open_test() {
  let reply_sub = process.new_subject()

  call(sm.Info(doorlock.GetStatus(reply_sub)), doorlock.Open)
  |> should.equal(sm.KeepState(data, []))

  process.receive(reply_sub, 0)
  |> should.equal(Ok(doorlock.Open))
}

// Unknown Events
/// Casts and other unrecognised events are silently ignored.
pub fn unknown_events_are_ignored_test() {
  let reply_sub = process.new_subject()

  call(sm.Cast(doorlock.GetStatus(reply_sub)), doorlock.Locked)
  |> should.equal(sm.KeepState(data, []))
}
