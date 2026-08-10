////
//// Tests for the reusable protocol fragments.
////
//// As with the other session tests, the file compiling is most of the point:
//// every composed protocol below had to type check, and every witness built
//// had to prove the two sides really fit. The bodies confirm the values
//// behave.
////
//// The composition tests are the interesting ones. They build multi-step
//// protocols out of fragments with nothing but type application, which is the
//// claim `eparch/session/patterns` makes in place of shipping a `seq`
//// operator.
////

import eparch/session/core
import eparch/session/duality
import eparch/session/patterns
import gleam/erlang/process

// COMPOSITION BY TYPE APPLICATION
//
// Filling a fragment's `then` hole with another fragment is sequencing. There
// is no combinator involved, and these aliases are the whole demonstration.

type AskOnce =
  patterns.Request(String, Int, core.Done)

type AskTwice =
  patterns.Request(String, Int, patterns.Request(String, Int, core.Done))

type ServeOnce =
  patterns.Serve(String, Int, core.Done)

type ServeTwice =
  patterns.Serve(String, Int, patterns.Serve(String, Int, core.Done))

fn asking() -> core.Channel(AskTwice, String) {
  core.begin(process.self(), protocol: "lookup")
}

fn serving() -> core.Channel(ServeTwice, String) {
  core.begin(process.self(), protocol: "lookup")
}

pub fn a_fragment_can_be_walked_test() {
  let channel: core.Channel(AskOnce, String) =
    core.begin(process.self(), protocol: "lookup")

  let #(question, channel) = core.send(channel, "balance")
  let channel = core.receive(channel, 100)

  assert question == "balance"
  assert core.finish(channel).protocol_name == "lookup"
}

pub fn two_fragments_sequence_by_filling_the_hole_test() {
  let channel = asking()

  let #(first, channel) = core.send(channel, "balance")
  let channel = core.receive(channel, 100)
  // The second Request is only reachable because it was substituted into the
  // first one's `then`.
  let #(second, channel) = core.send(channel, "limit")
  let channel = core.receive(channel, 500)

  assert first == "balance"
  assert second == "limit"
  assert core.finish(channel).protocol_name == "lookup"
}

pub fn the_serving_side_sequences_the_same_way_test() {
  let channel = serving()

  let channel = core.receive(channel, "balance")
  let #(first, channel) = core.send(channel, 100)
  let channel = core.receive(channel, "limit")
  let #(second, channel) = core.send(channel, 500)

  assert first == 100
  assert second == 500
  assert core.finish(channel).protocol_name == "lookup"
}

// WITNESS COMPOSITION
//
// A fragment's witness takes the continuation's witness, so composing two
// fragments is composing two functions. Again, no combinator.

fn asked_twice() -> duality.Dual(AskTwice, ServeTwice) {
  patterns.request(patterns.request(duality.done()))
}

pub fn fragment_witnesses_nest_test() {
  let #(client, server) = duality.connect(asked_twice(), asking(), serving())

  assert core.metadata(client).protocol_name == "lookup"
  assert core.metadata(server).protocol_name == "lookup"
}

pub fn serve_is_the_mirror_of_request_test() {
  let proof: duality.Dual(ServeOnce, AskOnce) = patterns.serve(duality.done())
  let asker = duality.opposite(proof, process.self(), protocol: "lookup")

  // Inference landed on the asking side, so the first obligation is to send.
  let #(question, _asker) = core.send(asker, "balance")
  assert question == "balance"
}

pub fn nesting_witnesses_has_no_depth_limit_test() {
  // Three rounds. Each application of `request` instantiates its type
  // variables afresh, which is what lets the nesting keep going.
  let proof: duality.Dual(
    patterns.Request(String, Int, AskTwice),
    patterns.Serve(String, Int, ServeTwice),
  ) = patterns.request(patterns.request(patterns.request(duality.done())))

  let client: core.Channel(patterns.Request(String, Int, AskTwice), String) =
    core.begin(process.self(), protocol: "lookup")
  let server: core.Channel(patterns.Serve(String, Int, ServeTwice), String) =
    core.begin(process.self(), protocol: "lookup")

  let #(client, _server) = duality.connect(proof, client, server)
  assert core.metadata(client).protocol_name == "lookup"
}

// What cannot be done: abstracting over the nesting.
//
//     let twice = fn(fragment) { fn(then) { fragment(fragment(then)) } }
//     twice(patterns.request)(duality.done())
//
// This does not compile. Applying `fragment` to its own result forces its
// argument and return types to unify, so `fragment` would have to be
// `fn(Dual(a, b)) -> Dual(a, b)`, and no real fragment is. Abstracting over a
// polymorphic function that must be instantiated differently at each use needs
// rank-2 polymorphism, which Gleam does not have.
//
// Nesting at the call site is unaffected, as the test above shows. The limit is
// only on writing a *generic* combinator, which is a second reason there is no
// `seq` in the library: not merely unnecessary, but impossible to write once
// and reuse.

// PROPOSAL AND DECISION

type Settle =
  patterns.Request(String, String, core.Done)

type Haggle =
  patterns.Propose(Int, Settle, core.Done)

type Consider =
  patterns.Decide(Int, patterns.Serve(String, String, core.Done), core.Done)

fn haggling() -> core.Channel(Haggle, String) {
  core.begin(process.self(), protocol: "haggle")
}

fn considering() -> core.Channel(Consider, String) {
  core.begin(process.self(), protocol: "haggle")
}

fn haggled() -> duality.Dual(Haggle, Consider) {
  patterns.propose(patterns.request(duality.done()), duality.done())
}

pub fn a_proposal_can_be_accepted_test() {
  let #(seller, buyer) = duality.connect(haggled(), haggling(), considering())

  let #(price, seller) = core.send(seller, 500)
  let buyer = core.receive(buyer, price)

  // The buyer decides; the seller follows.
  let buyer = core.choose_left(buyer)
  let seller = core.offered_left(seller)

  let #(card, seller) = core.send(seller, "visa")
  let buyer = core.receive(buyer, card)
  let #(receipt, buyer) = core.send(buyer, "paid")
  let seller = core.receive(seller, receipt)

  assert price == 500
  assert core.finish(seller).protocol_name == "haggle"
  assert core.finish(buyer).protocol_name == "haggle"
}

pub fn a_proposal_can_be_rejected_test() {
  let #(seller, buyer) = duality.connect(haggled(), haggling(), considering())

  let #(_price, seller) = core.send(seller, 5000)
  let buyer = core.receive(buyer, 5000)

  // The rejected branch ends immediately, and it is a different protocol from
  // the accepted one rather than the same one carrying a flag.
  assert core.finish(core.choose_right(buyer)).protocol_name == "haggle"
  assert core.finish(core.offered_right(seller)).protocol_name == "haggle"
}

pub fn decide_is_the_mirror_of_propose_test() {
  let proof: duality.Dual(Consider, Haggle) =
    patterns.decide(patterns.serve(duality.done()), duality.done())
  let #(buyer, _seller) = duality.connect(proof, considering(), haggling())

  assert core.metadata(buyer).protocol_name == "haggle"
}

// TWO-PHASE COMMIT

type Coordinator =
  patterns.Coordinate(String, Bool, String, core.Done)

type Participant =
  patterns.Participate(String, Bool, String, core.Done)

pub fn two_phase_commit_runs_both_sides_test() {
  let proof: duality.Dual(Coordinator, Participant) =
    patterns.coordinate(duality.done())

  let coordinator: core.Channel(Coordinator, String) =
    core.begin(process.self(), protocol: "2pc")
  let participant: core.Channel(Participant, String) =
    core.begin(process.self(), protocol: "2pc")

  let #(coordinator, participant) =
    duality.connect(proof, coordinator, participant)

  let #(proposal, coordinator) = core.send(coordinator, "transfer")
  let participant = core.receive(participant, proposal)

  let #(vote, participant) = core.send(participant, True)
  let coordinator = core.receive(coordinator, vote)

  let #(outcome, coordinator) = core.send(coordinator, "commit")
  let participant = core.receive(participant, outcome)

  assert vote == True
  assert outcome == "commit"
  assert core.finish(coordinator).protocol_name == "2pc"
  assert core.finish(participant).protocol_name == "2pc"
}

pub fn two_rounds_of_two_phase_commit_compose_test() {
  // Two rounds over one channel, again by filling the hole.
  let proof: duality.Dual(
    patterns.Coordinate(String, Bool, String, Coordinator),
    patterns.Participate(String, Bool, String, Participant),
  ) = patterns.coordinate(patterns.coordinate(duality.done()))

  let coordinator = core.begin(process.self(), protocol: "2pc")
  let participant = core.begin(process.self(), protocol: "2pc")
  let #(coordinator, _participant) =
    duality.connect(proof, coordinator, participant)

  let #(_p, coordinator) = core.send(coordinator, "first")
  let coordinator = core.receive(coordinator, True)
  let #(_o, coordinator) = core.send(coordinator, "commit")

  // Still going: the second round is where the first one's `then` was.
  let #(second, _coordinator) = core.send(coordinator, "second")
  assert second == "second"
}

pub fn participate_is_the_mirror_of_coordinate_test() {
  let proof: duality.Dual(Participant, Coordinator) =
    patterns.participate(duality.done())
  let coordinator = duality.opposite(proof, process.self(), protocol: "2pc")

  // Inference put us on the coordinating side, which sends first.
  let #(proposal, _coordinator) = core.send(coordinator, "transfer")
  assert proposal == "transfer"
}
