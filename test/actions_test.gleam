////
//// Integration tests for gen_statem actions: Stop, Postpone, NextEvent,
//// StateTimeout, GenericTimeout, and Cast.
////
//// Each section has its own state/msg types, prefixed to avoid constructor
//// name collisions across sections.
////

import eparch/state_machine
import gleam/erlang/process
import gleeunit/should

// STOP
type StopState {
  StopRunning
}

type StopMsg {
  Shutdown
}

fn stop_handler(
  event: state_machine.Event(StopState, StopMsg, Nil),
  _state: StopState,
  data: Nil,
) -> state_machine.Step(StopState, Nil, StopMsg, Nil) {
  case event {
    state_machine.Info(Shutdown) -> state_machine.stop(process.Normal)
    _ -> state_machine.keep_state(data, [])
  }
}

pub fn stop_normal_terminates_process_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: StopRunning, initial_data: Nil)
    |> state_machine.on_event(stop_handler)
    |> state_machine.start

  let monitor = process.monitor(machine.pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  process.send(machine.data, Shutdown)

  let assert Ok(down) = process.selector_receive(selector, 1000)
  down.reason |> should.equal(process.Normal)
}

// POSTPONE
type PostponeState {
  PostWaiting
  PostReady
}

type PostponeMsg {
  Go
  Action(reply_with: process.Subject(String))
}

fn postpone_handler(
  event: state_machine.Event(PostponeState, PostponeMsg, Nil),
  state: PostponeState,
  data: Nil,
) -> state_machine.Step(PostponeState, Nil, PostponeMsg, Nil) {
  case event, state {
    state_machine.Info(Action(_)), PostWaiting ->
      state_machine.keep_state(data, [state_machine.Postpone])

    state_machine.Info(Go), PostWaiting ->
      state_machine.next_state(PostReady, data, [])

    state_machine.Info(Action(reply_with: reply_sub)), PostReady -> {
      process.send(reply_sub, "handled")
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn postpone_redelivers_event_after_state_change_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: PostWaiting, initial_data: Nil)
    |> state_machine.on_event(postpone_handler)
    |> state_machine.start

  let reply_sub = process.new_subject()
  // Action arrives first but is postponed; Go triggers state change -> redeliver.
  process.send(machine.data, Action(reply_with: reply_sub))
  process.send(machine.data, Go)

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("handled")
}

// NEXT EVENT
// 1. Trigger 
// 2. NextEvent(Derived) -> internal event fires as Cast (Derived).

type NextEventState {
  NeActive
}

type NextEventMsg {
  Trigger(reply_with: process.Subject(String))
  Derived(reply_with: process.Subject(String))
}

fn next_event_handler(
  event: state_machine.Event(NextEventState, NextEventMsg, Nil),
  _state: NextEventState,
  data: Nil,
) -> state_machine.Step(NextEventState, Nil, NextEventMsg, Nil) {
  case event {
    state_machine.Info(Trigger(reply_with: reply_sub)) ->
      state_machine.keep_state(data, [
        state_machine.NextEvent(Derived(reply_sub)),
      ])

    state_machine.Cast(Derived(reply_with: reply_sub)) -> {
      process.send(reply_sub, "derived")
      state_machine.keep_state(data, [])
    }

    _ -> state_machine.keep_state(data, [])
  }
}

pub fn next_event_fires_synthesised_cast_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: NeActive, initial_data: Nil)
    |> state_machine.on_event(next_event_handler)
    |> state_machine.start

  let reply_sub = process.new_subject()
  process.send(machine.data, Trigger(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("derived")
}

// STATE TIMEOUT
type StTimeoutState {
  StIdle
  StActive
  StTimedOut
}

type StTimeoutMsg {
  StActivate
  StGetState(reply_with: process.Subject(StTimeoutState))
}

fn state_timeout_handler(
  event: state_machine.Event(StTimeoutState, StTimeoutMsg, Nil),
  state: StTimeoutState,
  data: Nil,
) -> state_machine.Step(StTimeoutState, Nil, StTimeoutMsg, Nil) {
  case event, state {
    state_machine.Info(StActivate), StIdle ->
      state_machine.next_state(StActive, data, [state_machine.StateTimeout(10)])

    state_machine.Timeout(state_machine.StateTimeoutType), StActive ->
      state_machine.next_state(StTimedOut, data, [])

    state_machine.Info(StGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn state_timeout_fires_and_transitions_state_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: StIdle, initial_data: Nil)
    |> state_machine.on_event(state_timeout_handler)
    |> state_machine.start

  process.send(machine.data, StActivate)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(machine.data, StGetState(reply_with: reply_sub))

  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(StTimedOut)
}

// State timeout is cancelled when leaving the state.
type CancelState {
  CIdle
  CActive
  CDone
}

type CancelMsg {
  CActivate
  CLeave
  CGetState(reply_with: process.Subject(CancelState))
}

fn cancel_handler(
  event: state_machine.Event(CancelState, CancelMsg, Nil),
  state: CancelState,
  data: Nil,
) -> state_machine.Step(CancelState, Nil, CancelMsg, Nil) {
  case event, state {
    state_machine.Info(CActivate), CIdle ->
      state_machine.next_state(CActive, data, [state_machine.StateTimeout(5000)])

    state_machine.Info(CLeave), CActive ->
      state_machine.next_state(CDone, data, [])

    state_machine.Info(CGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn state_timeout_is_cancelled_on_state_change_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CIdle, initial_data: Nil)
    |> state_machine.on_event(cancel_handler)
    |> state_machine.start

  process.send(machine.data, CActivate)
  process.send(machine.data, CLeave)

  let reply_sub = process.new_subject()
  process.send(machine.data, CGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(CDone)
}

// GENERIC TIMEOUT
type GenTimeoutState {
  GtWaiting
  GtTriggered
}

type GenTimeoutMsg {
  GtArm
  GtGetState(reply_with: process.Subject(GenTimeoutState))
}

fn generic_timeout_handler(
  event: state_machine.Event(GenTimeoutState, GenTimeoutMsg, Nil),
  state: GenTimeoutState,
  data: Nil,
) -> state_machine.Step(GenTimeoutState, Nil, GenTimeoutMsg, Nil) {
  case event, state {
    state_machine.Info(GtArm), GtWaiting ->
      state_machine.keep_state(data, [state_machine.GenericTimeout("tick", 10)])

    state_machine.Timeout(state_machine.GenericTimeoutType("tick")), GtWaiting ->
      state_machine.next_state(GtTriggered, data, [])

    state_machine.Info(GtGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn generic_timeout_fires_after_interval_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: GtWaiting, initial_data: Nil)
    |> state_machine.on_event(generic_timeout_handler)
    |> state_machine.start

  process.send(machine.data, GtArm)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(machine.data, GtGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(GtTriggered)
}

// CAST
//
// 1. state_machine.cast delivers `Cast(msg)`.
// 2. state_machine.send delivers Info(msg).
// 3. The handler only responds to `Cast`, `Info` is silently dropped.
type CastState {
  CastListening
}

type CastMsg {
  Ping(reply_with: process.Subject(String))
}

fn cast_handler(
  event: state_machine.Event(CastState, CastMsg, Nil),
  _state: CastState,
  data: Nil,
) -> state_machine.Step(CastState, Nil, CastMsg, Nil) {
  case event {
    state_machine.Cast(Ping(reply_with: reply_sub)) -> {
      process.send(reply_sub, "pong")
      state_machine.keep_state(data, [])
    }
    _ -> state_machine.keep_state(data, [])
  }
}

pub fn cast_delivers_message_as_cast_event_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CastListening, initial_data: Nil)
    |> state_machine.on_event(cast_handler)
    |> state_machine.start

  let reply_sub = process.new_subject()
  state_machine.cast(machine.data, Ping(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")
}

pub fn send_delivers_message_as_info_not_cast_test() {
  // state_machine.send -> Info(msg)
  // handler only handles Cast -> no reply -> timeout.
  let assert Ok(machine) =
    state_machine.new(initial_state: CastListening, initial_data: Nil)
    |> state_machine.on_event(cast_handler)
    |> state_machine.start

  let reply_sub = process.new_subject()
  state_machine.send(machine.data, Ping(reply_with: reply_sub))

  process.receive(reply_sub, 50) |> should.equal(Error(Nil))
}
