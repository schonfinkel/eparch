////
//// Tests for turning a projected protocol into Gleam source.
////
//// These check what the emitter says. Whether what it says is a module that
//// compiles and behaves is checked in `protocol_generated_test`, against
//// committed output, because no assertion about a string can establish that.
////
//// Splitting it that way is deliberate: a string test that also tried to be a
//// compilation test would end up asserting the whole file verbatim, and a test
//// that fails on every reworded doc comment stops being read.
////

import atm_protocol
import eparch/protocol/emit
import eparch/protocol/graph
import eparch/protocol/spec
import gleam/list
import gleam/string

// HELPERS

fn two_party(initial: String, body: spec.Spec) -> spec.Protocol {
  spec.Protocol(
    name: "example",
    roles: ["A", "B"],
    initial:,
    imports: [],
    spec: body,
  )
}

fn tell(label: String, payload: String, then: spec.Spec) -> spec.Spec {
  spec.Message(from: "A", to: "B", label:, payload:, then:)
}

fn arm(label: String, then: spec.Spec) -> spec.Branch {
  spec.Branch(label:, payload: "Nil", then:)
}

fn source_for(protocol: spec.Protocol, role: String) -> String {
  let assert Ok(module) = emit.module(protocol, for: role, under: "")
  module.source
}

fn declares(source: String, name: String) -> Bool {
  string.contains(source, "\npub type " <> name <> "\n")
}

fn defines(source: String, name: String) -> Bool {
  string.contains(source, "\npub fn " <> name <> "(")
}

// WHAT COMES OUT

pub fn every_participant_gets_a_module_test() {
  let assert Ok([customer, teller]) =
    emit.modules(atm_protocol.atm(), under: "banking")

  assert customer.name == "banking/atm/customer"
  assert teller.name == "banking/atm/teller"
}

pub fn a_prefix_is_optional_test() {
  let assert Ok([customer, ..]) = emit.modules(atm_protocol.atm(), under: "")

  assert customer.name == "atm/customer"
}

pub fn a_module_becomes_a_file_under_whichever_root_is_asked_for_test() {
  let assert Ok([customer, ..]) =
    emit.modules(atm_protocol.atm(), under: "banking")

  assert emit.path(customer, in: "src") == "src/banking/atm/customer.gleam"
  assert emit.path(customer, in: "test") == "test/banking/atm/customer.gleam"
  assert emit.path(customer, in: "") == "banking/atm/customer.gleam"
}

pub fn one_participant_can_be_emitted_alone_test() {
  let assert Ok(module) =
    emit.module(atm_protocol.atm(), for: "Teller", under: "")

  assert module.name == "atm/teller"
}

pub fn what_the_graph_refuses_never_reaches_a_file_test() {
  // A choice of one arm is not a choice, and the emitter does not get a say.
  let refused = two_party("Start", spec.Choice(at: "A", to: "B", branches: []))

  assert emit.modules(refused, under: "")
    == Error(graph.DegenerateChoice(at: "A", arms: 0))
}

// POSITIONS

pub fn every_state_becomes_a_type_and_a_function_test() {
  let assert Ok(projected) = graph.project(atm_protocol.atm(), "Customer")
  let source = source_for(atm_protocol.atm(), "Customer")

  // Nothing in the graph is left without a name to stand at, or a way past it.
  list.each(graph.state_names(projected), fn(name) {
    assert declares(source, name)
  })

  assert defines(source, "greeting")
  assert defines(source, "session")
  assert defines(source, "at_balance")
  assert defines(source, "ended")
}

pub fn a_send_and_a_receive_are_the_two_sides_of_one_message_test() {
  let customer = source_for(atm_protocol.atm(), "Customer")
  let teller = source_for(atm_protocol.atm(), "Teller")

  assert string.contains(
    customer,
    "-> Channel(core.Send(CardId, Session), msg)",
  )
  assert string.contains(teller, "-> Channel(core.Recv(CardId, Session), msg)")
}

pub fn the_end_of_a_protocol_unfolds_to_done_test() {
  assert string.contains(
    source_for(atm_protocol.atm(), "Customer"),
    "-> Channel(core.Done, msg)",
  )
}

pub fn a_loop_becomes_an_edge_back_to_a_name_test() {
  // The whole reason this module exists: `AtBalance` continues at `Session`,
  // which is a position it has already been through. Written as a nested type
  // that is an alias defined in terms of itself, and the compiler says no.
  assert string.contains(
    source_for(atm_protocol.atm(), "Customer"),
    "-> Channel(core.Recv(Amount, Session), msg)",
  )
}

pub fn the_starting_position_is_the_one_the_protocol_names_test() {
  assert string.contains(
    source_for(atm_protocol.atm(), "Customer"),
    "pub fn begin(peer: Pid) -> Channel(Greeting, msg) {",
  )
}

// CHOICES

pub fn a_choice_of_two_needs_no_invented_name_test() {
  let protocol =
    two_party(
      "Start",
      spec.Choice(at: "A", to: "B", branches: [
        arm("yes", spec.End),
        arm("no", spec.End),
      ]),
    )

  let source = source_for(protocol, "A")

  assert string.contains(
    source,
    "core.Choose(core.Send(Nil, Ended), core.Send(Nil, Ended))",
  )
  assert !string.contains(source, "Otherwise")
}

pub fn a_wider_choice_nests_through_names_of_its_own_test() {
  // `core` branches two ways at a time, so a choice of four needs two more
  // names than the graph has states, and they have to come from somewhere.
  let source = source_for(atm_protocol.atm(), "Customer")

  assert declares(source, "SessionOtherwise")
  assert string.contains(
    source,
    "-> Channel(core.Choose(core.Send(Amount, AtBalance), SessionOtherwise), msg)",
  )
}

pub fn a_shortcut_walks_the_nesting_in_one_step_test() {
  let source = source_for(atm_protocol.atm(), "Customer")

  // The first arm is one turn away.
  assert string.contains(source, "channel |> session |> core.choose_left")

  // The last is three, and nobody should have to count them by hand.
  assert string.contains(
    source,
    "  channel\n"
      <> "  |> session\n"
      <> "  |> core.choose_right\n"
      <> "  |> session_otherwise\n"
      <> "  |> core.choose_right\n",
  )
}

pub fn the_side_that_is_told_offers_rather_than_chooses_test() {
  let source = source_for(atm_protocol.atm(), "Teller")

  assert string.contains(source, "core.Offer(core.Recv(Amount, AtBalance)")
  assert string.contains(source, "channel |> session |> core.offered_left")
}

pub fn every_arm_gets_a_shortcut_named_after_its_label_test() {
  let source = source_for(atm_protocol.atm(), "Customer")

  assert defines(source, "session_deposit")
  assert defines(source, "session_withdraw")
  assert defines(source, "session_quit")
}

// NAMES

pub fn a_position_whose_name_is_a_keyword_gets_out_of_the_way_test() {
  // `derive` is reserved for a future Gleam, and a function called that
  // produces a syntax error pointing at an unrelated line.
  let protocol =
    two_party("Start", spec.At("derive", tell("x", "Nil", spec.End)))

  let source = source_for(protocol, "A")

  assert declares(source, "Derive")
  assert defines(source, "derive_")
  assert !defines(source, "derive")
}

pub fn a_state_named_after_a_keyword_in_disguise_is_left_alone_test() {
  let protocol =
    two_party("Start", spec.At("deriving", tell("x", "Nil", spec.End)))

  assert defines(source_for(protocol, "A"), "deriving")
}

// IMPORTS

pub fn the_payload_types_are_resolved_by_the_lines_the_protocol_carries_test() {
  let source = source_for(atm_protocol.atm(), "Customer")

  assert string.contains(
    source,
    "import atm_protocol.{type Amount, type CardId}",
  )
}

pub fn imports_come_out_in_the_order_the_formatter_wants_them_test() {
  let protocol =
    spec.Protocol(..two_party("Start", tell("x", "Zebra", spec.End)), imports: [
      "import zoo/zebra.{type Zebra}",
      "import aviary/auk",
    ])

  let assert [first, second, third, fourth, ..] =
    source_for(protocol, "A")
    |> string.split("\n")
    |> list.filter(string.starts_with(_, "import "))
    |> list.append(["", "", "", ""])

  assert [first, second, third, fourth]
    == [
      "import aviary/auk",
      "import eparch/session/core.{type Channel}",
      "import gleam/erlang/process.{type Pid}",
      "import zoo/zebra.{type Zebra}",
    ]
}

// CHECKING WHAT IS ALREADY THERE

fn wanted() -> List(emit.Module) {
  let assert Ok(modules) = emit.modules(atm_protocol.atm(), under: "generated")
  modules
}

pub fn a_module_that_was_never_written_is_absent_test() {
  let reviews = emit.review(wanted(), against: fn(_) { Error(Nil) })

  assert list.all(reviews, fn(review) { review.status == emit.Absent })
  assert !emit.agreed(reviews)
  assert list.map(reviews, emit.describe)
    == [
      "generated/atm/customer: missing, has never been generated",
      "generated/atm/teller: missing, has never been generated",
    ]
}

pub fn a_module_that_says_the_same_thing_is_current_test() {
  let reviews = emit.review(wanted(), against: fn(module) { Ok(module.source) })

  assert emit.agreed(reviews)
}

pub fn a_module_that_says_something_else_is_out_of_date_test() {
  let reviews =
    emit.review(wanted(), against: fn(module) {
      Ok(string.replace(module.source, each: "Session", with: "Sitting"))
    })

  assert list.all(reviews, fn(review) { review.status == emit.Different })
  assert !emit.agreed(reviews)
}

pub fn running_the_formatter_over_a_generated_module_does_not_age_it_test() {
  // The two things a formatter is allowed to do to source it agrees with:
  // move the line breaks, and add a trailing comma where it broke a call.
  let reviews =
    emit.review(wanted(), against: fn(module) {
      Ok(
        module.source
        |> string.replace(each: "\n", with: "\n\n")
        |> string.replace(each: ", msg) {", with: ",\n  msg,\n) {"),
      )
    })

  assert emit.agreed(reviews)
}
