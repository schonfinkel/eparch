////
//// Tests for the pure protocol core. Protocol positions are erased at run
//// time, so most of what happens below is plumbing: what the tests really
//// confirm is that the payloads survive each step and that the file compiles
//// at all, because every step in it had to type check against the protocol.
////
//// The guarantees that matter for this module are compile-time ones, and no
//// test can assert them: a program that fails to compile takes `gleam test`
//// down with it rather than passing, and Gleam has no `trybuild` equivalent.
//// Those rejections are catalogued in `docs/Session_Types.md` and verified by
//// hand with `gleam build` when a signature changes.
////
//// The one genuinely runtime-shaped thing here is peer monitoring, which does
//// start processes.
////

import eparch/session/core.{type Channel}
import gleam/erlang/process
import gleam/option.{None, Some}

// A greeter protocol, reused throughout: take a name, answer with a greeting,
// then decide whether to carry on or hang up.
type Greeter =
  core.Recv(
    String,
    core.Send(String, core.Choose(core.Recv(String, core.Done), core.Done)),
  )

type Greeted =
  core.Send(
    String,
    core.Recv(String, core.Offer(core.Send(String, core.Done), core.Done)),
  )

type Wire {
  Hello(String)
  Farewell(String)
}

fn greeter(peer: process.Pid) -> Channel(Greeter, Wire) {
  core.begin(peer, protocol: "greeting")
}

fn greeted(peer: process.Pid) -> Channel(Greeted, Wire) {
  core.begin(peer, protocol: "greeting")
}

// CHANNEL CONSTRUCTION
pub fn begin_records_the_peer_and_protocol_test() {
  let peer = process.self()
  let details = core.metadata(greeter(peer))

  assert details.protocol_name == "greeting"
  assert details.peer == peer
}

pub fn peer_is_readable_at_any_position_test() {
  let peer = process.self()
  let channel = greeter(peer)

  assert core.peer(channel) == peer

  // Still readable three steps in, at a completely different position.
  let channel = core.receive(channel, "ada")
  let #(_greeting, channel) = core.send(channel, "hello ada")

  assert core.peer(core.choose_right(channel)) == peer
}

pub fn distinct_channels_get_distinct_ids_test() {
  let peer = process.self()

  assert core.metadata(greeter(peer)).id != core.metadata(greeter(peer)).id
}

pub fn metadata_survives_every_step_test() {
  let peer = process.self()
  let channel = greeter(peer)
  let id = core.metadata(channel).id

  let channel = core.receive(channel, "ada")
  let #(_greeting, channel) = core.send(channel, "hello ada")
  let channel = core.choose_left(channel)
  let channel = core.receive(channel, "bye")

  assert core.finish(channel).id == id
}

// WALKING A PROTOCOL
pub fn a_full_greeter_run_reaches_done_test() {
  let channel = greeter(process.self())
  let channel = core.receive(channel, "ada")
  let #(greeting, channel) = core.send(channel, "hello ada")
  let channel = core.choose_left(channel)
  let channel = core.receive(channel, "bye")

  assert greeting == "hello ada"
  assert core.finish(channel).protocol_name == "greeting"
}

pub fn a_full_greeted_run_reaches_done_test() {
  let channel = greeted(process.self())
  let #(name, channel) = core.send(channel, "ada")
  let channel = core.receive(channel, "hello ada")
  let channel = core.offered_left(channel)
  let #(farewell, channel) = core.send(channel, "bye")

  assert name == "ada"
  assert farewell == "bye"
  assert core.finish(channel).protocol_name == "greeting"
}

pub fn choosing_right_ends_early_test() {
  let channel = greeter(process.self())
  let channel = core.receive(channel, "ada")
  let #(_greeting, channel) = core.send(channel, "hello ada")

  assert core.finish(core.choose_right(channel)).protocol_name == "greeting"
}

pub fn offered_right_ends_early_test() {
  let channel = greeted(process.self())
  let #(_name, channel) = core.send(channel, "ada")
  let channel = core.receive(channel, "hello ada")

  assert core.finish(core.offered_right(channel)).protocol_name == "greeting"
}

pub fn send_hands_back_the_message_it_checked_test() {
  let channel = core.receive(greeter(process.self()), "ada")
  let #(message, _channel) = core.send(channel, "hello ada")

  assert message == "hello ada"
}

// The wire type is pinned by the channel, so the protocol payload and the
// machine's message type are checked independently. This only compiles because
// `Wire` is what both channels above were opened with.
pub fn the_wire_type_is_pinned_by_the_channel_test() {
  let channel: Channel(Greeter, Wire) = greeter(process.self())
  let channel = core.receive(channel, "ada")
  let #(_greeting, channel) = core.send(channel, "hello ada")

  assert core.finish(core.choose_right(channel)).protocol_name == "greeting"
}

// The whole point of `send` handing the message back: this module does no
// I/O, so the caller wraps the checked value into its wire type and transmits
// it. The value that reached the wire is the same one the protocol checked.
pub fn the_caller_owns_the_transport_test() {
  let inbox = process.new_subject()
  let channel = core.receive(greeter(process.self()), "ada")

  let #(greeting, channel) = core.send(channel, "hello ada")
  process.send(inbox, Hello(greeting))

  assert process.receive(inbox, within: 100) == Ok(Hello("hello ada"))

  let channel = core.choose_left(channel)
  let #(farewell, _done) = core.send(greeted(process.self()), "bye")
  process.send(inbox, Farewell(farewell))

  assert process.receive(inbox, within: 100) == Ok(Farewell("bye"))
  assert core.close(channel).protocol_name == "greeting"
}

// PEER MONITORING
pub fn a_fresh_channel_is_not_watched_test() {
  assert core.watching(greeter(process.self())) == None
}

pub fn watch_installs_a_monitor_test() {
  let peer = process.spawn_unlinked(fn() { process.sleep_forever() })
  let channel = core.watch(greeter(peer))

  assert core.watching(channel) != None

  process.kill(peer)
}

pub fn peer_death_arrives_as_an_ordinary_message_test() {
  let peer = process.spawn_unlinked(fn() { process.sleep(50) })
  let channel = core.watch(greeter(peer))
  let assert Some(monitor) = core.watching(channel)

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  let assert Ok(process.ProcessDown(pid:, ..)) =
    process.selector_receive(from: selector, within: 1000)

  assert pid == peer
}

pub fn unwatch_stops_the_down_message_test() {
  let peer = process.spawn_unlinked(fn() { process.sleep(50) })
  let channel = core.watch(greeter(peer))
  let assert Some(monitor) = core.watching(channel)

  let channel = core.unwatch(channel)
  assert core.watching(channel) == None

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  assert process.selector_receive(from: selector, within: 200) == Error(Nil)
}

pub fn watching_twice_replaces_the_first_monitor_test() {
  let peer = process.spawn_unlinked(fn() { process.sleep(50) })
  let channel = core.watch(greeter(peer))
  let assert Some(first) = core.watching(channel)

  let channel = core.watch(channel)
  let assert Some(second) = core.watching(channel)

  assert first != second

  // Only the surviving monitor fires, so the first one stays silent.
  let stale =
    process.new_selector()
    |> process.select_specific_monitor(first, fn(down) { down })

  assert process.selector_receive(from: stale, within: 200) == Error(Nil)
}

pub fn finish_drops_the_monitor_test() {
  let peer = process.spawn_unlinked(fn() { process.sleep(50) })
  let channel = core.watch(greeter(peer))
  let assert Some(monitor) = core.watching(channel)

  let channel = core.receive(channel, "ada")
  let #(_greeting, channel) = core.send(channel, "hello ada")
  let _details = core.finish(core.choose_right(channel))

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  assert process.selector_receive(from: selector, within: 200) == Error(Nil)
}

// TWO PROCESSES, END TO END
//
// The only test here that is not plumbing. Two real processes walk opposite
// halves of the same protocol over real messages, each stepping its own
// channel as it goes. Nothing about the protocol is checked at run time; what
// this shows is that the compile-time discipline survives contact with an
// actual conversation, including the branch, where the server's `choose_left`
// and the client's `offered_left` have to be kept in step by an explicit
// message.

type ToServer {
  Name(String)
  Goodbye(String)
}

type ToClient {
  Greeting(String)
  CarryOn
  HangUp
}

fn run_server(
  inbox: process.Subject(ToServer),
  client: process.Subject(ToClient),
  peer: process.Pid,
  report: process.Subject(String),
) -> Nil {
  let channel: Channel(Greeter, ToServer) =
    core.begin(peer, protocol: "greeting")

  let assert Ok(Name(name)) = process.receive(inbox, within: 1000)
  let channel = core.receive(channel, name)

  let #(greeting, channel) = core.send(channel, "hello " <> name)
  process.send(client, Greeting(greeting))

  // Take the branch, and tell the peer which one so their `Offer` can follow.
  let channel = core.choose_left(channel)
  process.send(client, CarryOn)

  let assert Ok(Goodbye(farewell)) = process.receive(inbox, within: 1000)
  let channel = core.receive(channel, farewell)

  process.send(report, core.finish(channel).protocol_name <> ":" <> farewell)
}

pub fn two_processes_complete_a_protocol_test() {
  let client_inbox = process.new_subject()
  let handshake = process.new_subject()
  let report = process.new_subject()
  let client_pid = process.self()

  let server_pid =
    process.spawn_unlinked(fn() {
      let server_inbox = process.new_subject()
      process.send(handshake, server_inbox)
      run_server(server_inbox, client_inbox, client_pid, report)
    })

  let assert Ok(server_inbox) = process.receive(handshake, within: 1000)

  let channel: Channel(Greeted, ToClient) =
    core.watch(core.begin(server_pid, protocol: "greeting"))

  let #(name, channel) = core.send(channel, "ada")
  process.send(server_inbox, Name(name))

  let assert Ok(Greeting(greeting)) =
    process.receive(client_inbox, within: 1000)
  let channel = core.receive(channel, greeting)

  // The branch the server took arrives as an ordinary message, and the `case`
  // is what turns that runtime fact back into a static position.
  let channel = case process.receive(client_inbox, within: 1000) {
    Ok(CarryOn) -> core.offered_left(channel)
    _ -> panic as "server hung up"
  }

  let #(farewell, channel) = core.send(channel, "bye")
  process.send(server_inbox, Goodbye(farewell))

  assert greeting == "hello ada"
  assert core.finish(channel).protocol_name == "greeting"
  assert process.receive(report, within: 1000) == Ok("greeting:bye")
}

// Every branch of an `Offer` needs a continuation, and this is where that gets
// enforced: Gleam's ordinary `case` exhaustiveness at the point the incoming
// message is narrowed. Delete either arm below and the compiler objects, which
// is the work ST-DESIGN's `List(BranchHandler)` could not do, because a list
// has no arity the compiler knows about.
fn follow_branch(
  signal: ToClient,
  channel: Channel(core.Offer(core.Done, core.Done), ToClient),
) -> core.Metadata {
  case signal {
    CarryOn -> core.finish(core.offered_left(channel))
    HangUp -> core.finish(core.offered_right(channel))
    Greeting(_) -> panic as "not a branch signal"
  }
}

pub fn either_branch_of_an_offer_reaches_done_test() {
  let branch = fn() -> Channel(core.Offer(core.Done, core.Done), ToClient) {
    core.begin(process.self(), protocol: "branch")
  }

  assert follow_branch(CarryOn, branch()).protocol_name == "branch"
  assert follow_branch(HangUp, branch()).protocol_name == "branch"
}

pub fn close_abandons_from_a_position_that_still_owes_a_message_test() {
  let peer = process.spawn_unlinked(fn() { process.sleep(50) })
  let channel = core.watch(greeter(peer))
  let assert Some(monitor) = core.watching(channel)

  // Still at `Recv(String, ...)`, so `finish` would not compile here.
  let details = core.close(channel)
  assert details.protocol_name == "greeting"

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  assert process.selector_receive(from: selector, within: 200) == Error(Nil)
}
