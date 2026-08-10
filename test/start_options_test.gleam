////
//// Coverage for the new start surface introduced in `eparch/state_machine`:
//// `start_link`/`start`/`start_monitor`, `Local`/`Global`/`Via` registration,
//// `ServerRef` conversions, and the `with_debug`/`with_spawn_options`/
//// `with_hibernate_after` builder setters.
////

import eparch/start_options
import eparch/state_machine
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleeunit/should

@external(erlang, "erlang", "process_info")
fn process_info(pid: process.Pid, key: atom.Atom) -> Dynamic

@external(erlang, "global", "whereis_name")
fn global_whereis(name: atom.Atom) -> Dynamic

@external(erlang, "gen_statem", "cast")
fn gen_statem_cast(server: Dynamic, msg: Dynamic) -> atom.Atom

// ---------------------------------------------------------------------------
// Shared event type used across tests in this file.
// ---------------------------------------------------------------------------

type Msg {
  Ping(reply_with: process.Subject(String))
  Crash
}

type State {
  Running
}

fn handler(
  event: state_machine.Event(State, Msg, Nil),
  _state: State,
  data: Nil,
) -> state_machine.Step(State, Nil, Msg, Nil) {
  case event {
    state_machine.Info(Ping(reply_with:)) -> {
      process.send(reply_with, "pong")
      state_machine.keep_state(data, [])
    }
    state_machine.Cast(Ping(reply_with:)) -> {
      process.send(reply_with, "pong-cast")
      state_machine.keep_state(data, [])
    }
    state_machine.Cast(Crash) ->
      state_machine.stop(process.Abnormal(dynamic.string("boom")))
    state_machine.Info(Crash) ->
      state_machine.stop(process.Abnormal(dynamic.string("boom")))
    _ -> state_machine.keep_state(data, [])
  }
}

fn builder() -> state_machine.Builder(State, Nil, Msg, Nil) {
  state_machine.new(initial_state: Running, initial_data: Nil)
  |> state_machine.on_event(handler)
}

// ---------------------------------------------------------------------------
// start_link with Local name: ref_to_subject succeeds and process.named/1
// resolves the same pid.
// ---------------------------------------------------------------------------

pub fn start_link_local_resolves_via_process_named_test() {
  let name = process.new_name("eparch_test_local")
  let assert Ok(machine) =
    builder()
    |> state_machine.named(state_machine.Local(name))
    |> state_machine.start_link

  let assert Ok(subject) = state_machine.ref_to_subject(machine.ref)
  let assert Ok(named_pid) = process.named(name)
  named_pid |> should.equal(machine.pid)

  let reply = process.new_subject()
  process.send(subject, Ping(reply))
  let assert Ok(payload) = process.receive(reply, 1000)
  payload |> should.equal("pong")
}

// ---------------------------------------------------------------------------
// start (unlinked): the parent survives when the child crashes abnormally.
// ---------------------------------------------------------------------------

pub fn start_unlinked_does_not_propagate_crash_test() {
  let assert Ok(machine) = builder() |> state_machine.start

  let monitor = process.monitor(machine.pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  // Send Crash via cast: handler returns Stop(Abnormal). With no link, the
  // parent test process must keep running.
  state_machine.cast(machine.ref, Crash)
  let assert Ok(_down) = process.selector_receive(selector, 1000)

  // The fact that we got here at all is the test: the parent did not exit.
  process.self() |> should.not_equal(machine.pid)
}

// ---------------------------------------------------------------------------
// start_monitor: returns an atomic monitor that fires when the child dies.
// ---------------------------------------------------------------------------

pub fn start_monitor_delivers_down_test() {
  let assert Ok(monitored) = builder() |> state_machine.start_monitor

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitored.monitor, fn(down) { down })

  // Trigger an abnormal stop via cast (the link from start_monitor would
  // otherwise propagate to the test process, but gleeunit isolates each
  // test in its own process so the worst case is a single test failure).
  process.unlink(monitored.pid)
  state_machine.cast(monitored.ref, Crash)

  let assert Ok(down) = process.selector_receive(selector, 1000)
  case down {
    process.ProcessDown(pid:, ..) -> pid |> should.equal(monitored.pid)
    process.PortDown(..) -> panic as "expected ProcessDown"
  }
}

// ---------------------------------------------------------------------------
// Global registration: gen_statem:cast({global, _}, _) reaches the process,
// and ref_to_subject reports Error since there is no associated Subject.
// ---------------------------------------------------------------------------

pub fn global_named_start_routes_through_global_module_test() {
  let global_name = atom.create("eparch_test_global_machine")
  let assert Ok(machine) =
    builder()
    |> state_machine.named(state_machine.Global(global_name))
    |> state_machine.start_link

  // The global registry knows about the process.
  global_whereis(global_name)
  |> decode.run(decode.dynamic)
  |> should.be_ok

  // No Subject is exposed for global-registered servers.
  state_machine.ref_to_subject(machine.ref) |> should.equal(Error(Nil))

  // gen_statem:cast on the global tuple delivers a Cast event.
  let reply = process.new_subject()
  let global_target = encode_global_target(global_name)
  let cast_msg = encode_ping(reply)
  let _ = gen_statem_cast(global_target, cast_msg)

  let assert Ok(payload) = process.receive(reply, 1000)
  payload |> should.equal("pong-cast")
}

@external(erlang, "eparch_test_helpers", "encode_global_target")
fn encode_global_target(name: atom.Atom) -> Dynamic

@external(erlang, "eparch_test_helpers", "encode_ping")
fn encode_ping(reply: process.Subject(String)) -> Dynamic

// ---------------------------------------------------------------------------
// Via registration: the `global` module itself implements the `via` registry
// API (register_name/2, unregister_name/1, whereis_name/1, send/2), so we can
// use it as a stand-in via-target without authoring a custom registry.
// ---------------------------------------------------------------------------

pub fn via_global_routes_through_via_target_test() {
  let via_name = atom.create("eparch_test_via_machine")
  let assert Ok(machine) =
    builder()
    |> state_machine.named(state_machine.Via(
      module: atom.create("global"),
      name: encode_atom_as_term(via_name),
    ))
    |> state_machine.start_link

  state_machine.ref_to_subject(machine.ref) |> should.equal(Error(Nil))

  let reply = process.new_subject()
  state_machine.cast(machine.ref, Ping(reply))
  let assert Ok(payload) = process.receive(reply, 1000)
  payload |> should.equal("pong-cast")

  machine.pid |> should.not_equal(process.self())
}

@external(erlang, "eparch_test_helpers", "encode_atom_as_term")
fn encode_atom_as_term(value: atom.Atom) -> Dynamic

// ---------------------------------------------------------------------------
// with_spawn_options: the SpawnPriority is reflected in process_info.
// ---------------------------------------------------------------------------

pub fn with_spawn_options_sets_process_priority_test() {
  let assert Ok(machine) =
    builder()
    |> state_machine.with_spawn_options([
      start_options.SpawnPriority(start_options.PriorityHigh),
    ])
    |> state_machine.start_link

  let info = process_info(machine.pid, atom.create("priority"))
  decoded_priority_atom(info) |> should.equal(atom.create("high"))
}

fn decoded_priority_atom(info: Dynamic) -> atom.Atom {
  let decoder = {
    use _ <- decode.field(0, decode.dynamic)
    use value <- decode.field(1, atom.decoder())
    decode.success(value)
  }
  let assert Ok(value) = decode.run(info, decoder)
  value
}

// ---------------------------------------------------------------------------
// with_debug: starting with debug flags is a smoke test. The only useful
// observation is that the process starts and serves messages normally.
// ---------------------------------------------------------------------------

pub fn with_debug_accepts_log_flag_test() {
  let assert Ok(machine) =
    builder()
    |> state_machine.with_debug([start_options.DebugLog])
    |> state_machine.start_link

  let assert Ok(subject) = state_machine.ref_to_subject(machine.ref)
  let reply = process.new_subject()
  process.send(subject, Ping(reply))
  let assert Ok(payload) = process.receive(reply, 1000)
  payload |> should.equal("pong")
}

// ---------------------------------------------------------------------------
// with_hibernate_after: after the configured idle window, the process is in
// `erlang:hibernate/3` waiting for the next message.
// ---------------------------------------------------------------------------

pub fn with_hibernate_after_accepts_option_test() {
  // Smoke test for the with_hibernate_after wiring. The actual hibernation
  // behaviour is hard to assert reliably from the outside (process_info
  // does not always reflect the internal hibernate transition), so we
  // verify only that the option is accepted by the FFI and the process
  // continues to handle messages.
  let assert Ok(machine) =
    builder()
    |> state_machine.with_hibernate_after(start_options.Milliseconds(20))
    |> state_machine.start_link

  let assert Ok(subject) = state_machine.ref_to_subject(machine.ref)
  let reply = process.new_subject()
  process.send(subject, Ping(reply))
  let assert Ok(payload) = process.receive(reply, 1000)
  payload |> should.equal("pong")

  process.sleep(80)

  // Wake the process: must still respond after the hibernate window.
  let reply2 = process.new_subject()
  process.send(subject, Ping(reply2))
  let assert Ok(payload2) = process.receive(reply2, 1000)
  payload2 |> should.equal("pong")
}

// ---------------------------------------------------------------------------
// ref_from_subject and ref_from_pid round-trip with cast.
// ---------------------------------------------------------------------------

pub fn ref_from_subject_round_trip_test() {
  let assert Ok(machine) = builder() |> state_machine.start_link
  let assert Ok(subject) = state_machine.ref_to_subject(machine.ref)

  let wrapped = state_machine.ref_from_subject(subject)
  let reply = process.new_subject()
  state_machine.cast(wrapped, Ping(reply))

  let assert Ok(payload) = process.receive(reply, 1000)
  payload |> should.equal("pong-cast")
}

pub fn ref_from_pid_supports_cast_test() {
  let assert Ok(machine) = builder() |> state_machine.start_link

  let from_pid = state_machine.ref_from_pid(machine.pid)
  // ref_from_pid produces a ref with no associated Subject.
  state_machine.ref_to_subject(from_pid) |> should.equal(Error(Nil))

  let reply = process.new_subject()
  state_machine.cast(from_pid, Ping(reply))
  let assert Ok(payload) = process.receive(reply, 1000)
  payload |> should.equal("pong-cast")
}
