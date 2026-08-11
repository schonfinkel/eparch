////
//// Tests for the two-party duality layer. No protocol markers and no
//// witnesses survive to run time, so as with `session_core_test` the file
//// compiling at all is what confirms the types; the bodies below only confirm
//// the values behave.
////
//// Every witness built here is a proof that would not compile if the two
//// protocols disagreed. The rejections are catalogued in
//// `docs/Session_Types.md`.
////

import eparch/session/core
import eparch/session/duality
import gleam/erlang/process

// The greeter protocol and its exact reverse.
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

// The wire message type is irrelevant to duality, which is a relation between
// protocols. `String` stands in so the tests say nothing they do not mean.
fn greeter() -> core.Channel(Greeter, String) {
  core.begin(process.self(), protocol: "greeting")
}

fn greeted() -> core.Channel(Greeted, String) {
  core.begin(process.self(), protocol: "greeting")
}

/// This function compiling is the proof. Every line mirrors one row of the
/// duality table, and a single wrong line is reported where it was written.
fn proof() -> duality.Dual(Greeter, Greeted) {
  duality.receive(
    duality.send(duality.choose(duality.receive(duality.done()), duality.done())),
  )
}

// WITNESSES
pub fn a_witness_pairs_two_participants_test() {
  let #(server, client) = duality.connect(proof(), greeter(), greeted())

  assert core.metadata(server).protocol_name == "greeting"
  assert core.metadata(client).protocol_name == "greeting"
}

pub fn flip_reads_the_same_proof_backwards_test() {
  let #(client, server) =
    duality.connect(duality.flip(proof()), greeted(), greeter())

  assert core.metadata(client).protocol_name == "greeting"
  assert core.metadata(server).protocol_name == "greeting"
}

pub fn connect_pairs_without_moving_anything_test() {
  let server = greeter()
  let id = core.metadata(server).id
  let #(server, _client) = duality.connect(proof(), server, greeted())

  // Same channel back, not a copy at some other position.
  assert core.metadata(server).id == id
}

// DERIVING THE OTHER SIDE
pub fn the_second_protocol_can_be_left_to_inference_test() {
  // The client's protocol is not named anywhere in this function.
  // `<T as HasDual>::Dual`.
  let client = duality.opposite(proof(), process.self(), protocol: "greeting")

  // Proof that inference landed on `Greeted` and not something else: the
  // client's first obligation is to send a String. If it had landed on
  // `Greeter` this line would not compile.
  let #(name, _client) = core.send(client, "ada")

  assert name == "ada"
}

pub fn a_derived_participant_walks_the_whole_protocol_test() {
  let client = duality.opposite(proof(), process.self(), protocol: "greeting")
  let #(name, client) = core.send(client, "ada")
  let client = core.receive(client, "hello ada")
  let client = core.offered_left(client)
  let #(farewell, client) = core.send(client, "bye")

  assert name == "ada"
  assert farewell == "bye"
  assert core.finish(client).protocol_name == "greeting"
}

// The two sides, walked in lockstep, exchanging the same values. Each step
// type checks against its own protocol, and duality is what makes the pairing
// legitimate.
pub fn both_sides_agree_step_for_step_test() {
  let #(server, client) = duality.connect(proof(), greeter(), greeted())

  let #(name, client) = core.send(client, "ada")
  let server = core.receive(server, name)

  let #(greeting, server) = core.send(server, "hello " <> name)
  let client = core.receive(client, greeting)

  // The server picks; the client follows whatever it picked.
  let server = core.choose_left(server)
  let client = core.offered_left(client)

  let #(farewell, client) = core.send(client, "bye")
  let server = core.receive(server, farewell)

  assert greeting == "hello ada"
  assert core.finish(server).protocol_name == "greeting"
  assert core.finish(client).protocol_name == "greeting"
}

pub fn both_sides_agree_on_the_short_branch_test() {
  let #(server, client) = duality.connect(proof(), greeter(), greeted())

  let #(name, client) = core.send(client, "ada")
  let server = core.receive(server, name)
  let #(greeting, server) = core.send(server, "hello " <> name)
  let client = core.receive(client, greeting)

  // The server hangs up instead, and the client's matching branch also ends.
  assert core.finish(core.choose_right(server)).protocol_name == "greeting"
  assert core.finish(core.offered_right(client)).protocol_name == "greeting"
}

// SMALLER WITNESSES
pub fn done_is_dual_to_itself_test() {
  let proof: duality.Dual(core.Done, core.Done) = duality.done()
  let #(left, right) =
    duality.connect(
      proof,
      core.begin(process.self(), protocol: "empty"),
      core.begin(process.self(), protocol: "empty"),
    )

  assert core.finish(left).protocol_name == "empty"
  assert core.finish(right).protocol_name == "empty"
}

pub fn send_is_dual_to_receive_test() {
  let proof: duality.Dual(core.Send(Int, core.Done), core.Recv(Int, core.Done)) =
    duality.send(duality.done())

  let receiver = duality.opposite(proof, process.self(), protocol: "one-shot")
  let receiver = core.receive(receiver, 42)

  assert core.finish(receiver).protocol_name == "one-shot"
}

pub fn choose_is_dual_to_offer_test() {
  let proof: duality.Dual(
    core.Choose(core.Done, core.Done),
    core.Offer(core.Done, core.Done),
  ) = duality.choose(duality.done(), duality.done())

  let offerer = duality.opposite(proof, process.self(), protocol: "branch")

  assert core.finish(core.offered_right(offerer)).protocol_name == "branch"
}

pub fn offer_is_dual_to_choose_test() {
  let proof: duality.Dual(
    core.Offer(core.Done, core.Done),
    core.Choose(core.Done, core.Done),
  ) = duality.offer(duality.done(), duality.done())

  let chooser = duality.opposite(proof, process.self(), protocol: "branch")

  assert core.finish(core.choose_left(chooser)).protocol_name == "branch"
}

pub fn flipping_twice_is_the_original_proof_test() {
  let there_and_back: duality.Dual(Greeter, Greeted) =
    duality.flip(duality.flip(proof()))
  let #(server, _client) = duality.connect(there_and_back, greeter(), greeted())

  assert core.metadata(server).protocol_name == "greeting"
}
