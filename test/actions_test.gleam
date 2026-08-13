////
//// Integration tests for gen_statem actions: Stop, Postpone, NextEvent,
//// StateTimeout, GenericTimeout, Cast, and reqids (send_request).
////
//// Each section has its own state/msg types, prefixed to avoid constructor
//// name collisions across sections.
////

import eparch/start_options
import eparch/state_machine
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should

@external(erlang, "sys", "get_status")
fn sys_get_status(pid: process.Pid) -> Dynamic

@external(erlang, "erlang", "process_info")
fn process_info(pid: process.Pid, key: atom.Atom) -> Dynamic

/// Test helper: extract the underlying Subject from a Started machine.
/// Tests in this module only use unnamed and Local-named starts, so this
/// always succeeds; the assertion documents that assumption.
fn subject_of(
  machine: state_machine.Started(message),
) -> process.Subject(message) {
  let assert Ok(s) = state_machine.ref_to_subject(machine.ref)
  s
}

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
    |> state_machine.start_link

  let monitor = process.monitor(machine.pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  process.send(subject_of(machine), Shutdown)

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
    |> state_machine.start_link

  let reply_sub = process.new_subject()
  // Action arrives first but is postponed; Go triggers state change -> redeliver.
  process.send(subject_of(machine), Action(reply_with: reply_sub))
  process.send(subject_of(machine), Go)

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
        state_machine.NextEvent(state_machine.CastEvent, Derived(reply_sub)),
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
    |> state_machine.start_link

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), Trigger(reply_with: reply_sub))

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
  StTimedOutTick
  StGetState(reply_with: process.Subject(StTimeoutState))
}

fn state_timeout_handler(
  event: state_machine.Event(StTimeoutState, StTimeoutMsg, Nil),
  state: StTimeoutState,
  data: Nil,
) -> state_machine.Step(StTimeoutState, Nil, StTimeoutMsg, Nil) {
  case event, state {
    state_machine.Info(StActivate), StIdle ->
      state_machine.next_state(StActive, data, [
        state_machine.StateTimeout(state_machine.After(10), StTimedOutTick),
      ])

    state_machine.Timeout(state_machine.StateTimeoutType, _content), StActive ->
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
    |> state_machine.start_link

  process.send(subject_of(machine), StActivate)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), StGetState(reply_with: reply_sub))

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
      state_machine.next_state(CActive, data, [
        state_machine.StateTimeout(state_machine.After(5000), CActivate),
      ])

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
    |> state_machine.start_link

  process.send(subject_of(machine), CActivate)
  process.send(subject_of(machine), CLeave)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), CGetState(reply_with: reply_sub))
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
      state_machine.keep_state(data, [
        state_machine.GenericTimeout("tick", state_machine.After(10), GtArm),
      ])

    state_machine.Timeout(state_machine.GenericTimeoutType("tick"), _),
      GtWaiting
    -> state_machine.next_state(GtTriggered, data, [])

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
    |> state_machine.start_link

  process.send(subject_of(machine), GtArm)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), GtGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(GtTriggered)
}

type CstState {
  CstIdle
  CstActive
  CstTimedOut
}

type CstMsg {
  CstActivate
  CstCancel
  CstGetState(reply_with: process.Subject(CstState))
}

fn cancel_state_timeout_handler(
  event: state_machine.Event(CstState, CstMsg, Nil),
  state: CstState,
  data: Nil,
) -> state_machine.Step(CstState, Nil, CstMsg, Nil) {
  case event, state {
    state_machine.Info(CstActivate), CstIdle ->
      state_machine.next_state(CstActive, data, [
        state_machine.StateTimeout(state_machine.After(5000), CstActivate),
      ])

    state_machine.Info(CstCancel), CstActive ->
      state_machine.keep_state(data, [state_machine.cancel_state_timeout()])

    state_machine.Timeout(state_machine.StateTimeoutType, _), CstActive ->
      state_machine.next_state(CstTimedOut, data, [])

    state_machine.Info(CstGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn cancel_state_timeout_prevents_fire_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CstIdle, initial_data: Nil)
    |> state_machine.on_event(cancel_state_timeout_handler)
    |> state_machine.start_link

  process.send(subject_of(machine), CstActivate)
  process.send(subject_of(machine), CstCancel)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), CstGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(CstActive)
}

type CgtState {
  CgtWaiting
  CgtTriggered
}

type CgtMsg {
  CgtArm
  CgtCancel
  CgtGetState(reply_with: process.Subject(CgtState))
}

fn cancel_generic_timeout_handler(
  event: state_machine.Event(CgtState, CgtMsg, Nil),
  state: CgtState,
  data: Nil,
) -> state_machine.Step(CgtState, Nil, CgtMsg, Nil) {
  case event, state {
    state_machine.Info(CgtArm), CgtWaiting ->
      state_machine.keep_state(data, [
        state_machine.GenericTimeout("tick", state_machine.After(5000), CgtArm),
      ])

    state_machine.Info(CgtCancel), CgtWaiting ->
      state_machine.keep_state(data, [
        state_machine.cancel_generic_timeout("tick"),
      ])

    state_machine.Timeout(state_machine.GenericTimeoutType("tick"), _),
      CgtWaiting
    -> state_machine.next_state(CgtTriggered, data, [])

    state_machine.Info(CgtGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn cancel_generic_timeout_prevents_fire_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CgtWaiting, initial_data: Nil)
    |> state_machine.on_event(cancel_generic_timeout_handler)
    |> state_machine.start_link

  process.send(subject_of(machine), CgtArm)
  process.send(subject_of(machine), CgtCancel)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), CgtGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(CgtWaiting)
}

type UstState {
  UstWaiting
  UstFired
}

type UstMsg {
  UstArm
  UstUpdate
  UstGetState(reply_with: process.Subject(UstState))
}

fn update_state_timeout_handler(
  event: state_machine.Event(UstState, UstMsg, Nil),
  state: UstState,
  data: Nil,
) -> state_machine.Step(UstState, Nil, UstMsg, Nil) {
  case event, state {
    state_machine.Info(UstArm), UstWaiting ->
      state_machine.keep_state(data, [
        state_machine.StateTimeout(state_machine.After(200), UstArm),
      ])

    state_machine.Info(UstUpdate), UstWaiting ->
      state_machine.keep_state(data, [
        state_machine.update_state_timeout(UstUpdate),
      ])

    state_machine.Timeout(state_machine.StateTimeoutType, _), UstWaiting ->
      state_machine.next_state(UstFired, data, [])

    state_machine.Info(UstGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn update_state_timeout_fires_without_restart_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: UstWaiting, initial_data: Nil)
    |> state_machine.on_event(update_state_timeout_handler)
    |> state_machine.start_link

  process.send(subject_of(machine), UstArm)
  process.send(subject_of(machine), UstUpdate)
  process.sleep(300)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), UstGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(UstFired)
}

// EVENT TIMEOUT (unnamed gen_statem `timeout()`)
//
// Defining behaviour: any event arriving in the current state cancels it.
type EvtState {
  EvtWaiting
  EvtFired
  EvtPoked
}

type EvtMsg {
  EvtArm
  EvtPoke
  EvtTick
  EvtGetState(reply_with: process.Subject(EvtState))
}

fn event_timeout_handler(
  event: state_machine.Event(EvtState, EvtMsg, Nil),
  state: EvtState,
  data: Nil,
) -> state_machine.Step(EvtState, Nil, EvtMsg, Nil) {
  case event, state {
    state_machine.Info(EvtArm), EvtWaiting ->
      state_machine.keep_state(data, [
        state_machine.EventTimeout(state_machine.After(10), EvtTick),
      ])

    state_machine.Timeout(state_machine.EventTimeoutType, EvtTick), EvtWaiting
    -> state_machine.next_state(EvtFired, data, [])

    state_machine.Info(EvtPoke), EvtWaiting ->
      state_machine.next_state(EvtPoked, data, [])

    state_machine.Info(EvtGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn event_timeout_fires_and_delivers_content_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: EvtWaiting, initial_data: Nil)
    |> state_machine.on_event(event_timeout_handler)
    |> state_machine.start_link

  process.send(subject_of(machine), EvtArm)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), EvtGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  // Only fires if the handler matched on the supplied EvtTick content.
  s |> should.equal(EvtFired)
}

pub fn event_timeout_cancelled_by_subsequent_event_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: EvtWaiting, initial_data: Nil)
    |> state_machine.on_event(event_timeout_handler)
    |> state_machine.start_link

  // Arm a 50ms event timeout, then send an unrelated event well before it
  // would have fired. gen_statem auto-cancels event timeouts when any other
  // event arrives, so the timer never fires; EvtPoke takes the machine to
  // EvtPoked instead of EvtFired.
  process.send(subject_of(machine), EvtArm)
  process.send(subject_of(machine), EvtPoke)
  process.sleep(80)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), EvtGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(EvtPoked)
}

// CANCEL EVENT TIMEOUT
type CetState {
  CetWaiting
  CetTimedOut
}

type CetMsg {
  CetArm
  CetCancel
  CetTick
  CetGetState(reply_with: process.Subject(CetState))
}

fn cancel_event_timeout_handler(
  event: state_machine.Event(CetState, CetMsg, Nil),
  state: CetState,
  data: Nil,
) -> state_machine.Step(CetState, Nil, CetMsg, Nil) {
  case event, state {
    state_machine.Info(CetArm), CetWaiting ->
      state_machine.keep_state(data, [
        state_machine.EventTimeout(state_machine.After(20), CetTick),
      ])

    state_machine.Info(CetCancel), CetWaiting ->
      state_machine.keep_state(data, [state_machine.cancel_event_timeout()])

    state_machine.Timeout(state_machine.EventTimeoutType, _), CetWaiting ->
      state_machine.next_state(CetTimedOut, data, [])

    state_machine.Info(CetGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn cancel_event_timeout_prevents_fire_test() {
  // CetCancel cancels the just-armed event timeout. The implicit cancel-on-
  // any-event also applies, but we cancel explicitly to exercise that path.
  let assert Ok(machine) =
    state_machine.new(initial_state: CetWaiting, initial_data: Nil)
    |> state_machine.on_event(cancel_event_timeout_handler)
    |> state_machine.start_link

  process.send(subject_of(machine), CetArm)
  process.send(subject_of(machine), CetCancel)
  process.sleep(50)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), CetGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(CetWaiting)
}

// ABSOLUTE TIMEOUT (At(deadline))
@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

type AbsState {
  AbsWaiting
  AbsFired
}

type AbsMsg {
  AbsArm(deadline_ms: Int)
  AbsTick
  AbsGetState(reply_with: process.Subject(AbsState))
}

fn abs_timeout_handler(
  event: state_machine.Event(AbsState, AbsMsg, Nil),
  state: AbsState,
  data: Nil,
) -> state_machine.Step(AbsState, Nil, AbsMsg, Nil) {
  case event, state {
    state_machine.Info(AbsArm(deadline_ms:)), AbsWaiting ->
      state_machine.keep_state(data, [
        state_machine.StateTimeout(state_machine.At(deadline_ms), AbsTick),
      ])

    state_machine.Timeout(state_machine.StateTimeoutType, AbsTick), AbsWaiting
    -> state_machine.next_state(AbsFired, data, [])

    state_machine.Info(AbsGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn absolute_state_timeout_fires_near_deadline_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: AbsWaiting, initial_data: Nil)
    |> state_machine.on_event(abs_timeout_handler)
    |> state_machine.start_link

  // Compute a deadline 20ms in the future on the monotonic clock.
  let deadline = monotonic_time(atom.create("millisecond")) + 20
  process.send(subject_of(machine), AbsArm(deadline_ms: deadline))
  process.sleep(80)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), AbsGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(AbsFired)
}

// CUSTOM CONTENT round-trip through a state timeout.
type CntState {
  CntWaiting
  CntDone
}

type CntMsg {
  CntArm
  CntTick(retry: Int, label: String)
  CntGetReceived(reply_with: process.Subject(CntMsg))
}

type CntData {
  CntData(received: option.Option(CntMsg))
}

fn custom_content_handler(
  event: state_machine.Event(CntState, CntMsg, Nil),
  state: CntState,
  data: CntData,
) -> state_machine.Step(CntState, CntData, CntMsg, Nil) {
  case event, state {
    state_machine.Info(CntArm), CntWaiting ->
      state_machine.keep_state(data, [
        state_machine.StateTimeout(
          state_machine.After(10),
          CntTick(retry: 3, label: "boom"),
        ),
      ])

    state_machine.Timeout(state_machine.StateTimeoutType, content), CntWaiting
    ->
      state_machine.next_state(
        CntDone,
        CntData(received: option.Some(content)),
        [],
      )

    state_machine.Info(CntGetReceived(reply_with: reply_sub)), _ -> {
      case data.received {
        option.Some(msg) -> process.send(reply_sub, msg)
        option.None -> Nil
      }
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn state_timeout_delivers_custom_content_test() {
  let assert Ok(machine) =
    state_machine.new(
      initial_state: CntWaiting,
      initial_data: CntData(received: option.None),
    )
    |> state_machine.on_event(custom_content_handler)
    |> state_machine.start_link

  process.send(subject_of(machine), CntArm)
  process.sleep(40)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), CntGetReceived(reply_with: reply_sub))
  let assert Ok(received) = process.receive(reply_sub, 1000)
  received |> should.equal(CntTick(retry: 3, label: "boom"))
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
    |> state_machine.start_link

  let reply_sub = process.new_subject()
  state_machine.cast(machine.ref, Ping(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")
}

pub fn send_delivers_message_as_info_not_cast_test() {
  // state_machine.send -> Info(msg)
  // handler only handles Cast -> no reply -> timeout.
  let assert Ok(machine) =
    state_machine.new(initial_state: CastListening, initial_data: Nil)
    |> state_machine.on_event(cast_handler)
    |> state_machine.start_link

  let reply_sub = process.new_subject()
  state_machine.send(subject_of(machine), Ping(reply_with: reply_sub))

  process.receive(reply_sub, 50) |> should.equal(Error(Nil))
}

// CHANGE CALLBACK MODULE
//
// Switching to `statem_ffi` itself is a safe no-op: the machine keeps the
// same behaviour but exercises the FFI translation path end-to-end.
type CbState {
  CbListening
}

type CbMsg {
  CbSwitch
  CbPing(reply_with: process.Subject(String))
}

fn change_callback_handler(
  event: state_machine.Event(CbState, CbMsg, Nil),
  _state: CbState,
  data: Nil,
) -> state_machine.Step(CbState, Nil, CbMsg, Nil) {
  case event {
    state_machine.Info(CbSwitch) ->
      state_machine.keep_state(data, [
        state_machine.change_callback_module(atom.create("statem_ffi")),
      ])

    state_machine.Info(CbPing(reply_with: reply_sub)) -> {
      process.send(reply_sub, "pong")
      state_machine.keep_state(data, [])
    }

    _ -> state_machine.keep_state(data, [])
  }
}

pub fn change_callback_module_keeps_machine_alive_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CbListening, initial_data: Nil)
    |> state_machine.on_event(change_callback_handler)
    |> state_machine.start_link

  process.send(subject_of(machine), CbSwitch)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), CbPing(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")
}

// PUSH / POP CALLBACK MODULE
fn push_pop_handler(
  event: state_machine.Event(CbState, CbMsg, Nil),
  _state: CbState,
  data: Nil,
) -> state_machine.Step(CbState, Nil, CbMsg, Nil) {
  case event {
    state_machine.Info(CbSwitch) ->
      state_machine.keep_state(data, [
        state_machine.push_callback_module(atom.create("statem_ffi")),
        state_machine.pop_callback_module(),
      ])

    state_machine.Info(CbPing(reply_with: reply_sub)) -> {
      process.send(reply_sub, "pong")
      state_machine.keep_state(data, [])
    }

    _ -> state_machine.keep_state(data, [])
  }
}

pub fn push_then_pop_callback_module_roundtrip_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CbListening, initial_data: Nil)
    |> state_machine.on_event(push_pop_handler)
    |> state_machine.start_link

  process.send(subject_of(machine), CbSwitch)

  let reply_sub = process.new_subject()
  process.send(subject_of(machine), CbPing(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")
}

// REQIDS (send_request / OTP 25+)
//
// The server receives Call(from, msg) events and must reply with the
// Reply(from, value) action. This is different from the Info-based pattern
// used by state_machine.call / process.call.
//

type ReqState {
  ReqRunning
}

type ReqMsg {
  GetCounter
  Increment
}

fn reqid_handler(
  event: state_machine.Event(ReqState, ReqMsg, Int),
  _state: ReqState,
  data: Int,
) -> state_machine.Step(ReqState, Int, ReqMsg, Int) {
  case event {
    state_machine.Call(from, GetCounter) ->
      state_machine.keep_state(data, [state_machine.Reply(from, data)])
    state_machine.Info(Increment) -> state_machine.keep_state(data + 1, [])
    _ -> state_machine.keep_state(data, [])
  }
}

pub fn send_request_returns_reply_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 0)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start_link

  let request: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, GetCounter)
  let assert Ok(count) = state_machine.receive_response(request, 1000)
  count |> should.equal(0)
}

pub fn send_request_sees_latest_state_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 0)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start_link

  process.send(subject_of(machine), Increment)
  process.send(subject_of(machine), Increment)

  let request: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, GetCounter)
  let assert Ok(count) = state_machine.receive_response(request, 1000)
  count |> should.equal(2)
}

pub fn request_ids_size_reflects_pending_requests_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 0)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start_link

  let collection: state_machine.RequestIdCollection(String, Int) =
    state_machine.request_ids_new()
  state_machine.request_ids_size(collection) |> should.equal(0)

  let collection =
    state_machine.send_request_to_collection(
      machine.ref,
      GetCounter,
      "first",
      collection,
    )
  state_machine.request_ids_size(collection) |> should.equal(1)

  let collection =
    state_machine.send_request_to_collection(
      machine.ref,
      GetCounter,
      "second",
      collection,
    )
  state_machine.request_ids_size(collection) |> should.equal(2)

  let assert state_machine.GotReply(_, _, collection) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  let assert state_machine.GotReply(_, _, collection) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  state_machine.request_ids_size(collection) |> should.equal(0)
}

pub fn send_request_to_collection_delivers_both_replies_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 42)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start_link

  let collection: state_machine.RequestIdCollection(String, Int) =
    state_machine.request_ids_new()
  let collection =
    state_machine.send_request_to_collection(
      machine.ref,
      GetCounter,
      "a",
      collection,
    )
  let collection =
    state_machine.send_request_to_collection(
      machine.ref,
      GetCounter,
      "b",
      collection,
    )

  let assert state_machine.GotReply(value1, _label1, collection) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  let assert state_machine.GotReply(value2, _label2, _) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )

  value1 |> should.equal(42)
  value2 |> should.equal(42)
}

pub fn request_ids_to_list_contains_all_entries_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 0)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start_link

  let collection: state_machine.RequestIdCollection(String, Int) =
    state_machine.request_ids_new()
  let collection =
    state_machine.send_request_to_collection(
      machine.ref,
      GetCounter,
      "x",
      collection,
    )
  let collection =
    state_machine.send_request_to_collection(
      machine.ref,
      GetCounter,
      "y",
      collection,
    )

  let entries = state_machine.request_ids_to_list(collection)
  list.length(entries) |> should.equal(2)

  let assert state_machine.GotReply(_, _, collection) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  let assert state_machine.GotReply(_, _, _) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
}

pub fn request_ids_add_manually_adds_to_collection_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 7)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start_link

  let request: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, GetCounter)
  let collection: state_machine.RequestIdCollection(String, Int) =
    state_machine.request_ids_new()
  let collection =
    state_machine.request_ids_add(
      request_id: request,
      label: "manual",
      to: collection,
    )
  state_machine.request_ids_size(collection) |> should.equal(1)

  let assert state_machine.GotReply(value, label, _) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  value |> should.equal(7)
  label |> should.equal("manual")
}

// STOP AND REPLY
type SarState {
  SarRunning
}

type SarMsg {
  SarGetAndStop
}

fn stop_and_reply_handler(
  event: state_machine.Event(SarState, SarMsg, String),
  _state: SarState,
  _data: Nil,
) -> state_machine.Step(SarState, Nil, SarMsg, String) {
  case event {
    state_machine.Call(from, SarGetAndStop) ->
      state_machine.stop_and_reply(process.Normal, [
        state_machine.Reply(from, "bye"),
      ])
    _ -> state_machine.keep_state(Nil, [])
  }
}

pub fn stop_and_reply_sends_reply_before_stopping_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: SarRunning, initial_data: Nil)
    |> state_machine.on_event(stop_and_reply_handler)
    |> state_machine.start_link

  let monitor = process.monitor(machine.pid)
  let sel =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(d) { d })

  let req: state_machine.RequestId(String) =
    state_machine.send_request(machine.ref, SarGetAndStop)
  let assert Ok(reply) = state_machine.receive_response(req, 1000)
  reply |> should.equal("bye")

  let assert Ok(down) = process.selector_receive(sel, 1000)
  down.reason |> should.equal(process.Normal)
}

// HIBERNATE AFTER
type HibState {
  HibIdle
}

type HibMsg {
  HibPing(reply_with: process.Subject(String))
}

fn hibernate_after_handler(
  event: state_machine.Event(HibState, HibMsg, Nil),
  _state: HibState,
  data: Nil,
) -> state_machine.Step(HibState, Nil, HibMsg, Nil) {
  case event {
    state_machine.Info(HibPing(reply_with: reply_sub)) -> {
      process.send(reply_sub, "pong")
      state_machine.keep_state(data, [])
    }
    _ -> state_machine.keep_state(data, [])
  }
}

// Configures a 10ms timer, sleeps 50ms, checks process_info(pid, current_function) 
// reports gen_statem:loop_hibernate/3, then verifies the machine still responds
// to a message after waking.
pub fn hibernate_after_puts_idle_process_into_hibernation_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: HibIdle, initial_data: Nil)
    |> state_machine.with_hibernate_after(start_options.Milliseconds(10))
    |> state_machine.on_event(hibernate_after_handler)
    |> state_machine.start_link

  // Wait long enough for the idle timer to fire. When hibernating, the
  // process's current_function is gen_statem:loop_hibernate/3.
  process.sleep(50)

  let info = process_info(machine.pid, atom.create("current_function"))
  string.inspect(info)
  |> string.contains("Hibernate")
  |> should.equal(True)

  // Sending a message wakes the process; the handler still runs.
  let reply_sub = process.new_subject()
  process.send(subject_of(machine), HibPing(reply_with: reply_sub))
  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")
}

// Negative control confirming the option is actually doing the work.
pub fn machine_without_hibernate_after_does_not_hibernate_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: HibIdle, initial_data: Nil)
    |> state_machine.on_event(hibernate_after_handler)
    |> state_machine.start_link

  process.sleep(50)

  let info = process_info(machine.pid, atom.create("current_function"))
  string.inspect(info)
  |> string.contains("Hibernate")
  |> should.equal(False)
}

// ON FORMAT STATUS
type FmtState {
  FmtIdle
  FmtReady
}

type FmtMsg {
  FmtGoReady
}

type FmtData {
  FmtSecret(value: Int)
  FmtRedacted(label: String)
}

fn fmt_handler(
  event: state_machine.Event(FmtState, FmtMsg, Nil),
  _state: FmtState,
  data: FmtData,
) -> state_machine.Step(FmtState, FmtData, FmtMsg, Nil) {
  case event {
    state_machine.Info(FmtGoReady) ->
      state_machine.next_state(FmtReady, data, [])
    _ -> state_machine.keep_state(data, [])
  }
}

pub fn on_format_status_overrides_data_in_status_report_test() {
  let assert Ok(machine) =
    state_machine.new(
      initial_state: FmtIdle,
      initial_data: FmtSecret(value: 42),
    )
    |> state_machine.on_event(fmt_handler)
    |> state_machine.on_format_status(fn(status) {
      let label = case status.data {
        FmtSecret(value: v) -> "FORMATTED:" <> int.to_string(v)
        FmtRedacted(label: l) -> l
      }
      state_machine.Status(..status, data: FmtRedacted(label: label))
    })
    |> state_machine.start_link

  let status = sys_get_status(machine.pid)
  string.inspect(status)
  |> string.contains("FORMATTED:42")
  |> should.equal(True)
}

pub fn machine_without_format_status_still_appears_in_status_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: FmtIdle, initial_data: FmtSecret(value: 0))
    |> state_machine.on_event(fmt_handler)
    |> state_machine.start_link

  // Should not crash; sys:get_status returns a non-empty term.
  let _ = sys_get_status(machine.pid)
  Nil
}

// CLIENT API WRAPPERS (issue #32): stop_server, send_reply(s), wait_response,
// check_response, receive_response_blocking.

type ClientState {
  ClientRunning
}

type ClientMsg {
  CliGet
  // CliAsk parks the caller's From in an external stash so the test process
  // can reply with send_reply / send_replies from outside the callback.
  CliAsk(stash: process.Subject(state_machine.From(Int)))
  // CliNoReply intentionally leaves the call without a reply, used to drive
  // wait_response_timeout into ReceiveTimeout.
  CliNoReply
}

fn client_handler(
  event: state_machine.Event(ClientState, ClientMsg, Int),
  _state: ClientState,
  data: Int,
) -> state_machine.Step(ClientState, Int, ClientMsg, Int) {
  case event {
    state_machine.Call(from, CliGet) ->
      state_machine.keep_state(data, [state_machine.Reply(from, data)])
    state_machine.Call(from, CliAsk(stash)) -> {
      process.send(stash, from)
      state_machine.keep_state(data, [])
    }
    state_machine.Call(_from, CliNoReply) -> state_machine.keep_state(data, [])
    _ -> state_machine.keep_state(data, [])
  }
}

pub fn stop_server_terminates_machine_with_normal_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ClientRunning, initial_data: 0)
    |> state_machine.on_event(client_handler)
    |> state_machine.start_link

  let monitor = process.monitor(machine.pid)
  let sel =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(d) { d })

  state_machine.stop_server(subject_of(machine))

  let assert Ok(down) = process.selector_receive(sel, 1000)
  down.reason |> should.equal(process.Normal)
}

pub fn stop_server_with_custom_reason_test() {
  // gen_statem:start_link links the machine to the test process, so a
  // non-normal exit reason propagates here and proc_lib:stop/3 also raises
  // for non-normal reasons. Trap exits so the test process survives.
  process.trap_exits(True)

  let assert Ok(machine) =
    state_machine.new(initial_state: ClientRunning, initial_data: 0)
    |> state_machine.on_event(client_handler)
    |> state_machine.start_link

  let monitor = process.monitor(machine.pid)
  let sel =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(d) { d })

  let reason = process.Abnormal(dynamic.string("shutdown_requested"))
  let _ =
    process.spawn_unlinked(fn() {
      state_machine.stop_server_with(subject_of(machine), reason, 1000)
    })

  // The exact reason round-tripping through gleam_erlang's monitor decoder
  // is governed by the existing convert_exit_reason/cast_exit_reason pair;
  // here we just confirm the 3-arg call drives the machine to terminate.
  let assert Ok(process.ProcessDown(pid: down_pid, ..)) =
    process.selector_receive(sel, 1000)
  down_pid |> should.equal(machine.pid)

  process.flush_messages()
  process.trap_exits(False)
}

pub fn send_reply_from_external_process_completes_call_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ClientRunning, initial_data: 0)
    |> state_machine.on_event(client_handler)
    |> state_machine.start_link

  let stash: process.Subject(state_machine.From(Int)) = process.new_subject()
  let req: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, CliAsk(stash))

  let assert Ok(from) = process.receive(stash, 1000)
  state_machine.send_reply(from, 123)

  let assert Ok(reply) = state_machine.receive_response(req, 1000)
  reply |> should.equal(123)
}

pub fn send_replies_completes_multiple_calls_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ClientRunning, initial_data: 0)
    |> state_machine.on_event(client_handler)
    |> state_machine.start_link

  let stash: process.Subject(state_machine.From(Int)) = process.new_subject()

  let req1: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, CliAsk(stash))
  let req2: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, CliAsk(stash))

  let assert Ok(from1) = process.receive(stash, 1000)
  let assert Ok(from2) = process.receive(stash, 1000)

  state_machine.send_replies([#(from1, 1), #(from2, 2)])

  let assert Ok(r1) = state_machine.receive_response(req1, 1000)
  let assert Ok(r2) = state_machine.receive_response(req2, 1000)
  r1 |> should.equal(1)
  r2 |> should.equal(2)
}

pub fn wait_response_returns_reply_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ClientRunning, initial_data: 99)
    |> state_machine.on_event(client_handler)
    |> state_machine.start_link

  let req: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, CliGet)
  let assert Ok(value) = state_machine.wait_response(req)
  value |> should.equal(99)
}

pub fn wait_response_timeout_yields_receive_timeout_when_no_reply_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ClientRunning, initial_data: 0)
    |> state_machine.on_event(client_handler)
    |> state_machine.start_link

  let req: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, CliNoReply)

  state_machine.wait_response_timeout(req, 50)
  |> should.equal(Error(state_machine.ReceiveTimeout))
}

pub fn check_response_returns_none_for_unrelated_message_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ClientRunning, initial_data: 0)
    |> state_machine.on_event(client_handler)
    |> state_machine.start_link

  let req: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, CliGet)

  // An int dynamic is not a gen_statem reply tuple.
  let unrelated = dynamic.int(42)
  state_machine.check_response(unrelated, req)
  |> should.equal(Ok(option.None))

  // Drain the real reply so the mailbox is clean for the next test.
  let _ = state_machine.receive_response(req, 1000)
}

pub fn check_response_returns_some_for_matching_reply_test() {
  process.flush_messages()

  let assert Ok(machine) =
    state_machine.new(initial_state: ClientRunning, initial_data: 11)
    |> state_machine.on_event(client_handler)
    |> state_machine.start_link

  let req: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, CliGet)

  let selector =
    process.new_selector()
    |> process.select_other(fn(msg) { msg })
  let assert Ok(raw) = process.selector_receive(from: selector, within: 1000)

  case state_machine.check_response(raw, req) {
    Ok(option.Some(value)) -> value |> should.equal(11)
    other -> {
      string.inspect(other) |> should.equal("Ok(Some(11))")
      Nil
    }
  }
}

pub fn receive_response_blocking_returns_reply_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ClientRunning, initial_data: 7)
    |> state_machine.on_event(client_handler)
    |> state_machine.start_link

  let req: state_machine.RequestId(Int) =
    state_machine.send_request(machine.ref, CliGet)
  let assert Ok(value) = state_machine.receive_response_blocking(req)
  value |> should.equal(7)
}
