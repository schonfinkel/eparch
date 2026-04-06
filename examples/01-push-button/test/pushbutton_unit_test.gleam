////
//// Unit tests for the pushbutton event handler.
////
//// These tests call `handle_event` directly without spawning a process,
//// so they run fast and are fully deterministic.
////
//// `from_for_testing()` produces a dummy `From` value that satisfies the
//// type-checker and supports equality comparisons, it is never passed to
//// the `gen_statem` runtime.
////

import eparch/state_machine as sm
import gleeunit/should
import pushbutton

/// Pushing when Off transitions to On and increments the counter.
/// The caller receives the count *before* the increment (0 -> reply 0, data 1).
pub fn push_when_off_transitions_to_on_test() {
  let from = sm.from_for_testing()

  pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.Off, 0)
  |> should.equal(sm.NextState(pushbutton.On, 1, [sm.Reply(from, 0)]))
}

/// Pushing when On transitions back to Off without changing the counter.
/// The caller receives the current count.
pub fn push_when_on_transitions_to_off_test() {
  let from = sm.from_for_testing()

  pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.On, 3)
  |> should.equal(sm.NextState(pushbutton.Off, 3, [sm.Reply(from, 3)]))
}

/// GetCount in the Off state keeps state and replies with the current count.
pub fn get_count_when_off_returns_count_test() {
  let from = sm.from_for_testing()

  pushbutton.handle_event(sm.Call(from, pushbutton.GetCount), pushbutton.Off, 0)
  |> should.equal(sm.KeepState(0, [sm.Reply(from, 0)]))
}

/// GetCount in the On state keeps state and replies with the current count.
pub fn get_count_when_on_returns_count_test() {
  let from = sm.from_for_testing()

  pushbutton.handle_event(sm.Call(from, pushbutton.GetCount), pushbutton.On, 5)
  |> should.equal(sm.KeepState(5, [sm.Reply(from, 5)]))
}

/// The press count only grows on Off -> On transitions, never on On -> Off.
/// Simulates three consecutive pushes and inspects each resulting Step.
pub fn count_increments_only_on_off_to_on_transitions_test() {
  let from = sm.from_for_testing()

  // Push 1
  // - Off -> On, Data 0 -> 1
  // - reply 0
  pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.Off, 0)
  |> should.equal(sm.NextState(pushbutton.On, 1, [sm.Reply(from, 0)]))

  // Push 2
  // - On -> Off, Data stays 1
  // - reply 1
  pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.On, 1)
  |> should.equal(sm.NextState(pushbutton.Off, 1, [sm.Reply(from, 1)]))

  // Push 3
  // - Off -> On, Data 1 -> 2
  // - reply 1
  pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.Off, 1)
  |> should.equal(sm.NextState(pushbutton.On, 2, [sm.Reply(from, 1)]))
}

/// Casts and other non-Call events are ignored (keep_state with no actions).
pub fn unexpected_events_are_silently_ignored_test() {
  pushbutton.handle_event(sm.Cast(pushbutton.Push), pushbutton.Off, 0)
  |> should.equal(sm.KeepState(0, []))
}

/// After N complete On/Off cycles the press count equals N.
/// Verifies count correctness across five full cycles.
pub fn count_equals_number_of_on_cycles_test() {
  let from = sm.from_for_testing()

  // Off -> On transitions interleaved with On -> Off transitions.
  let _s1 =
    pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.Off, 0)
  // -> On, data=1
  let _s2 =
    pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.On, 1)
  // -> Off, data=1
  let _s3 =
    pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.Off, 1)
  // -> On, data=2
  let _s4 =
    pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.On, 2)
  // -> Off, data=2
  let _s5 =
    pushbutton.handle_event(sm.Call(from, pushbutton.Push), pushbutton.Off, 2)
  // -> On, data=3

  // GetCount while On must report 3 without changing state.
  pushbutton.handle_event(sm.Call(from, pushbutton.GetCount), pushbutton.On, 3)
  |> should.equal(sm.KeepState(3, [sm.Reply(from, 3)]))
}

/// GetCount is valid regardless of whether the button is On or Off.
pub fn get_count_is_state_agnostic_test() {
  let from = sm.from_for_testing()
  let count = 7

  pushbutton.handle_event(
    sm.Call(from, pushbutton.GetCount),
    pushbutton.Off,
    count,
  )
  |> should.equal(sm.KeepState(count, [sm.Reply(from, count)]))

  pushbutton.handle_event(
    sm.Call(from, pushbutton.GetCount),
    pushbutton.On,
    count,
  )
  |> should.equal(sm.KeepState(count, [sm.Reply(from, count)]))
}
