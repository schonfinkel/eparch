////
//// Tests for the protocol-driven state machine.
////
//// Unlike the pure-core tests these are integration-style, per the repo's
//// convention: real processes, real monitors, real `sys:get_status/1`. What
//// they check is that the compile-time position discipline survives being run
//// by a `gen_statem`, including the parts that are genuinely runtime concerns:
//// out-of-order events, violations, timeouts and termination.
////
//// The protocol below is the same greeter used in `session_core_test`, now
//// driven by a machine instead of walked by hand.
////

import eparch/protocol_machine as pm
import eparch/session/core.{type Channel}
import eparch/start_options
import eparch/state_machine
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/string

// The protocol
type Greeter =
  core.Recv(
    String,
    core.Send(String, core.Choose(core.Recv(String, core.Done), core.Done)),
  )

type Wire {
  /// From the peer: the name to be greeted.
  Name(String)
  /// From the peer: the closing word.
  Farewell(String)
  /// Internal: wake a position that has nothing to wait for.
  Proceed
  /// A synchronous question, answered at whatever position we are at.
  WhereAreWe
  /// Never part of the protocol. Used to test rejection.
  Nonsense
  /// Fired by the session timeout.
  Stalled
}

type Tag {
  AwaitingName
  Greeting
  Choosing
  AwaitingFarewell
  Finished
}

/// What the machine accumulates as it goes, so we can prove data survives
/// every transition.
type Transcript {
  Transcript(lines: List(String))
}

/// One alias, so no position function has to name five type parameters.
type Position(protocol) =
  pm.ProtocolState(protocol, Tag, Transcript, Wire, String)

fn note(transcript: Transcript, line: String) -> Transcript {
  Transcript(lines: [line, ..transcript.lines])
}

// The positions
//
// One function per protocol position. Each is annotated with the position it
// sits at, and that annotation is what every transition inside it is checked
// against.

fn awaiting_name(
  channel: Channel(Greeter, Wire),
  transcript: Transcript,
  report: Subject(String),
) -> Position(Greeter) {
  pm.state(
    tag: AwaitingName,
    at: channel,
    data: transcript,
    handler: fn(event, channel, data) {
      case event {
        state_machine.Cast(Name(name)) ->
          pm.accept(
            at: channel,
            message: name,
            actions: [pm.advance_now(Proceed)],
            then: fn(next) { greeting(next, note(data, name), name, report) },
          )

        state_machine.Call(from, WhereAreWe) ->
          pm.hold(data:, actions: [state_machine.reply(from, "awaiting_name")])

        state_machine.Cast(Nonsense) ->
          pm.reject("the protocol wants a name here", [])

        // Legitimate but early: hold it until a position wants it.
        _ -> pm.postpone()
      }
    },
  )
}

fn greeting(
  channel: Channel(
    core.Send(String, core.Choose(core.Recv(String, core.Done), core.Done)),
    Wire,
  ),
  transcript: Transcript,
  name: String,
  report: Subject(String),
) -> Position(
  core.Send(String, core.Choose(core.Recv(String, core.Done), core.Done)),
) {
  pm.state(
    tag: Greeting,
    at: channel,
    data: transcript,
    handler: fn(event, channel, data) {
      case event {
        state_machine.Cast(Proceed) ->
          pm.transmit(
            at: channel,
            message: "hello " <> name,
            actions: [pm.advance_now(Proceed)],
            then: fn(greeting, next) {
              // This module does no I/O, so putting it on the wire happens here.
              process.send(report, greeting)
              choosing(next, note(data, greeting), report)
            },
          )

        state_machine.Call(from, WhereAreWe) ->
          pm.hold(data:, actions: [state_machine.reply(from, "greeting")])

        _ -> pm.postpone()
      }
    },
  )
}

fn choosing(
  channel: Channel(core.Choose(core.Recv(String, core.Done), core.Done), Wire),
  transcript: Transcript,
  report: Subject(String),
) -> Position(core.Choose(core.Recv(String, core.Done), core.Done)) {
  pm.state(
    tag: Choosing,
    at: channel,
    data: transcript,
    handler: fn(event, channel, data) {
      case event {
        state_machine.Cast(Proceed) ->
          pm.pick_left(at: channel, actions: [], then: fn(next) {
            process.send(report, "carry-on")
            awaiting_farewell(next, data, report)
          })

        state_machine.Call(from, WhereAreWe) ->
          pm.hold(data:, actions: [state_machine.reply(from, "choosing")])

        _ -> pm.postpone()
      }
    },
  )
}

fn awaiting_farewell(
  channel: Channel(core.Recv(String, core.Done), Wire),
  transcript: Transcript,
  report: Subject(String),
) -> Position(core.Recv(String, core.Done)) {
  pm.state(
    tag: AwaitingFarewell,
    at: channel,
    data: transcript,
    handler: fn(event, channel, data) {
      case event {
        state_machine.Cast(Farewell(word)) ->
          pm.accept(
            at: channel,
            message: word,
            actions: [pm.advance_now(Proceed)],
            then: fn(next) { finished(next, note(data, word), report) },
          )

        state_machine.Call(from, WhereAreWe) ->
          pm.hold(data:, actions: [
            state_machine.reply(from, "awaiting_farewell"),
          ])

        state_machine.Timeout(_, Stalled) ->
          pm.fail(
            at: channel,
            reason: process.Abnormal(dynamic.string("stalled")),
            actions: [],
          )

        _ -> pm.postpone()
      }
    },
  )
}

fn finished(
  channel: Channel(core.Done, Wire),
  transcript: Transcript,
  report: Subject(String),
) -> Position(core.Done) {
  pm.state(
    tag: Finished,
    at: channel,
    data: transcript,
    handler: fn(event, channel, data) {
      case event {
        state_machine.Cast(Proceed) -> {
          // The transcript, in order, proving data survived every transition.
          process.send(report, "done:" <> join(data.lines))
          pm.complete(at: channel, actions: [])
        }
        _ -> pm.postpone()
      }
    },
  )
}

fn join(lines: List(String)) -> String {
  case lines {
    [] -> ""
    [only] -> only
    [head, ..rest] -> join(rest) <> "," <> head
  }
}

// Starting one
fn start(report: Subject(String)) -> state_machine.Started(Wire) {
  let channel: Channel(Greeter, Wire) =
    core.begin(process.self(), protocol: "greeting")

  let assert Ok(started) =
    pm.new(awaiting_name(channel, Transcript(lines: []), report))
    |> pm.start_link

  started
}

/// Ask the machine where it is, through a real `gen_statem` call, so the
/// answer comes back from a `Reply` action returned by whichever handler is
/// currently installed.
fn where_are_we(started: state_machine.Started(Wire)) -> String {
  let request: state_machine.RequestId(String) =
    state_machine.send_request(started.ref, WhereAreWe)
  let assert Ok(answer) = state_machine.receive_response(request, 1000)
  answer
}

// ===============================================================
// A protocol, end to end
// ===============================================================

pub fn a_machine_walks_the_whole_protocol_test() {
  let report = process.new_subject()
  let started = start(report)
  let monitor = process.monitor(started.pid)

  state_machine.cast(started.ref, Name("ada"))
  state_machine.cast(started.ref, Farewell("bye"))

  assert process.receive(report, within: 1000) == Ok("hello ada")
  assert process.receive(report, within: 1000) == Ok("carry-on")
  assert process.receive(report, within: 1000) == Ok("done:ada,hello ada,bye")

  // `complete` stops the machine normally once the protocol reaches Done.
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(reason:, ..)) =
    process.selector_receive(from: selector, within: 1000)

  assert reason == process.Normal
}

// ===============================================================
// The position survives every transition
// ===============================================================

pub fn the_position_is_visible_at_each_step_test() {
  let report = process.new_subject()
  let started = start(report)

  assert where_are_we(started) == "awaiting_name"

  state_machine.cast(started.ref, Name("ada"))
  let assert Ok("hello ada") = process.receive(report, within: 1000)
  let assert Ok("carry-on") = process.receive(report, within: 1000)

  // Three positions later, and the machine answers from the right handler.
  assert where_are_we(started) == "awaiting_farewell"

  state_machine.cast(started.ref, Farewell("bye"))
  let assert Ok("done:ada,hello ada,bye") =
    process.receive(report, within: 1000)
}

pub fn the_gen_statem_state_is_the_tag_test() {
  let report = process.new_subject()
  let started = start(report)

  // The tag is what `gen_statem` sees, so it is what shows up in sys status.
  let status = sys_get_status(started.pid)
  assert string.contains(status, "awaiting_name")

  state_machine.cast(started.ref, Name("ada"))
  let assert Ok("hello ada") = process.receive(report, within: 1000)
  let assert Ok("carry-on") = process.receive(report, within: 1000)

  assert string.contains(sys_get_status(started.pid), "awaiting_farewell")
}

pub fn internal_data_accumulates_across_positions_test() {
  let report = process.new_subject()
  let started = start(report)

  state_machine.cast(started.ref, Name("grace"))
  let assert Ok(_) = process.receive(report, within: 1000)
  let assert Ok(_) = process.receive(report, within: 1000)
  state_machine.cast(started.ref, Farewell("later"))

  // One line contributed by each of three different positions.
  assert process.receive(report, within: 1000)
    == Ok("done:grace,hello grace,later")
}

// ===============================================================
// Out-of-order events
// ===============================================================

pub fn an_early_message_is_postponed_and_redelivered_test() {
  let report = process.new_subject()
  let started = start(report)

  // The farewell arrives before the name, three positions too early. It has to
  // survive being postponed at every position in between.
  state_machine.cast(started.ref, Farewell("bye"))
  state_machine.cast(started.ref, Name("ada"))

  assert process.receive(report, within: 1000) == Ok("hello ada")
  assert process.receive(report, within: 1000) == Ok("carry-on")
  assert process.receive(report, within: 1000) == Ok("done:ada,hello ada,bye")
}

pub fn a_postponed_message_is_not_lost_while_waiting_test() {
  let report = process.new_subject()
  let started = start(report)

  state_machine.cast(started.ref, Farewell("bye"))

  // Still at the first position: the early event changed nothing.
  assert where_are_we(started) == "awaiting_name"

  state_machine.cast(started.ref, Name("ada"))
  let assert Ok("hello ada") = process.receive(report, within: 1000)
  let assert Ok("carry-on") = process.receive(report, within: 1000)
  assert process.receive(report, within: 1000) == Ok("done:ada,hello ada,bye")
}

// ===============================================================
// Violations
// ===============================================================

pub fn a_violation_is_refused_without_stopping_the_machine_test() {
  let report = process.new_subject()
  let started = start(report)

  state_machine.cast(started.ref, Nonsense)

  // Still alive, still at the same position.
  assert process.is_alive(started.pid)
  assert where_are_we(started) == "awaiting_name"

  // And the protocol still runs to completion afterwards.
  state_machine.cast(started.ref, Name("ada"))
  state_machine.cast(started.ref, Farewell("bye"))
  let assert Ok("hello ada") = process.receive(report, within: 1000)
  let assert Ok("carry-on") = process.receive(report, within: 1000)
  assert process.receive(report, within: 1000) == Ok("done:ada,hello ada,bye")
}

pub fn the_violation_hook_sees_the_reason_and_position_test() {
  let violations = process.new_subject()
  let report = process.new_subject()

  let channel: Channel(Greeter, Wire) =
    core.begin(process.self(), protocol: "greeting")

  let assert Ok(started) =
    pm.new(awaiting_name(channel, Transcript(lines: []), report))
    |> pm.on_violation(fn(violation) {
      process.send(violations, #(violation.reason, violation.tag))
    })
    |> pm.start_link

  state_machine.cast(started.ref, Nonsense)

  assert process.receive(violations, within: 1000)
    == Ok(#("the protocol wants a name here", AwaitingName))
}

pub fn no_hook_means_a_violation_is_silently_refused_test() {
  let report = process.new_subject()
  let started = start(report)

  state_machine.cast(started.ref, Nonsense)

  assert process.is_alive(started.pid)
  assert where_are_we(started) == "awaiting_name"
}

// ===============================================================
// Session timeouts
// ===============================================================

pub fn a_stalled_protocol_times_out_test() {
  let report = process.new_subject()
  let channel: Channel(Greeter, Wire) =
    core.begin(process.self(), protocol: "greeting")

  // Deliberately unlinked: this machine is meant to exit abnormally, and a
  // link would take the test process down with it.
  let assert Ok(started) =
    pm.new(awaiting_name(channel, Transcript(lines: []), report))
    |> pm.with_timeout(after: 100, sending: Stalled)
    |> pm.start

  let monitor = process.monitor(started.pid)

  // Reach the position that waits on the peer, then say nothing.
  state_machine.cast(started.ref, Name("ada"))
  let assert Ok("hello ada") = process.receive(report, within: 1000)
  let assert Ok("carry-on") = process.receive(report, within: 1000)

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(reason:, ..)) =
    process.selector_receive(from: selector, within: 2000)

  // The reason makes a round trip through the FFI, which encodes `Abnormal(t)`
  // as `{abnormal, t}`, and the monitor then classifies that whole tuple as an
  // abnormal reason again. So it comes back wrapped twice, and matching the
  // exact shape would be asserting the encoding rather than the behaviour.
  assert string.contains(string.inspect(reason), "stalled")
}

pub fn without_a_timeout_a_stalled_protocol_just_waits_test() {
  let report = process.new_subject()
  let started = start(report)

  state_machine.cast(started.ref, Name("ada"))
  let assert Ok("hello ada") = process.receive(report, within: 1000)
  let assert Ok("carry-on") = process.receive(report, within: 1000)

  process.sleep(200)

  assert process.is_alive(started.pid)
  assert where_are_we(started) == "awaiting_farewell"
}

// ===============================================================
// Lowering to the plain builder
// ===============================================================

pub fn to_state_machine_inherits_the_underlying_builder_test() {
  let report = process.new_subject()
  let channel: Channel(Greeter, Wire) =
    core.begin(process.self(), protocol: "greeting")

  // Everything `state_machine` offers is applied at that level rather than
  // duplicated on the protocol builder.
  let assert Ok(started) =
    pm.new(awaiting_name(channel, Transcript(lines: []), report))
    |> pm.to_state_machine
    |> state_machine.with_hibernate_after(start_options.Milliseconds(60_000))
    |> state_machine.with_debug([])
    |> state_machine.start_link

  state_machine.cast(started.ref, Name("ada"))
  assert process.receive(report, within: 1000) == Ok("hello ada")
}

pub fn a_machine_can_be_started_unlinked_test() {
  let report = process.new_subject()
  let channel: Channel(Greeter, Wire) =
    core.begin(process.self(), protocol: "greeting")

  let assert Ok(started) =
    pm.new(awaiting_name(channel, Transcript(lines: []), report))
    |> pm.start

  assert process.is_alive(started.pid)
  state_machine.cast(started.ref, Name("ada"))
  assert process.receive(report, within: 1000) == Ok("hello ada")
}

// helpers
/// `sys:get_status/1` renders the `gen_statem` state, which is where the tag
/// shows up. Rendering it to text is Erlang's job; there is no Gleam shape for
/// the status tuple.
@external(erlang, "eparch_test_helpers", "sys_get_status_text")
fn sys_get_status(pid: process.Pid) -> String
