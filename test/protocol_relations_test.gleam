////
//// Tests for the coinductive checks over projected protocols.
////
//// Every protocol here repeats, which is the point: these are the questions
//// `eparch/session/duality` cannot answer, because a finite value cannot
//// witness an infinite unfolding. That each check terminates at all is a
//// result rather than an implementation detail, so the fixtures loop
//// deliberately.
////

import eparch/protocol/graph
import eparch/protocol/relations
import eparch/protocol/spec
import gleam/list

// FIXTURES

/// An ATM that goes round until the customer says otherwise.
fn atm() -> spec.Protocol {
  teller_offering([
    spec.Branch("deposit", "Amount", balance_then_repeat()),
    spec.Branch("quit", "Nil", spec.End),
  ])
}

/// The same, with one more thing the customer may ask for.
fn atm_with_transfers() -> spec.Protocol {
  teller_offering([
    spec.Branch("deposit", "Amount", balance_then_repeat()),
    spec.Branch("quit", "Nil", spec.End),
    spec.Branch("transfer", "Amount", balance_then_repeat()),
  ])
}

fn teller_offering(branches: List(spec.Branch)) -> spec.Protocol {
  spec.Protocol(
    name: "atm",
    roles: ["Customer", "Teller"],
    initial: "Greeting",
    imports: [],
    spec: spec.Message(
      from: "Customer",
      to: "Teller",
      label: "card",
      payload: "CardId",
      then: spec.Loop(
        "session",
        spec.Choice(at: "Customer", to: "Teller", branches:),
      ),
    ),
  )
}

fn balance_then_repeat() -> spec.Spec {
  spec.Message(
    from: "Teller",
    to: "Customer",
    label: "balance",
    payload: "Amount",
    then: spec.Continue("session"),
  )
}

fn sides(protocol: spec.Protocol) -> #(graph.Graph, graph.Graph) {
  let assert Ok([customer, teller]) = graph.compile(protocol)
  #(customer, teller)
}

// DUALITY

pub fn the_two_projections_of_a_repeating_protocol_are_dual_test() {
  let #(customer, teller) = sides(atm())

  // The claim `session/duality` cannot make, because this protocol loops and
  // there is no finite value that witnesses an infinite unfolding.
  let assert Ok(_) = relations.dual(customer, teller)
}

pub fn duality_relates_the_states_that_face_each_other_test() {
  let #(customer, teller) = sides(atm())
  let assert Ok(relations.Witness(pairs:)) = relations.dual(customer, teller)

  assert pairs
    == [
      #("Greeting", "Greeting"),
      #("Session", "Session"),
      #("AtBalance", "AtBalance"),
      #("Ended", "Ended"),
    ]
}

pub fn the_check_terminates_on_a_protocol_that_repeats_test() {
  let #(customer, teller) = sides(atm())
  let assert Ok(relations.Witness(pairs:)) = relations.dual(customer, teller)

  // Four pairs, not an unfolding. The cycle is tied off by assuming the pair
  // already visited is related, which is what makes this decidable.
  assert list.length(pairs) == 4
}

pub fn a_participant_is_not_dual_to_itself_test() {
  let #(customer, _teller) = sides(atm())

  let assert Error(relations.Mismatch(reason: relations.Incompatible(..), ..)) =
    relations.dual(customer, customer)
}

pub fn a_payload_that_disagrees_breaks_duality_test() {
  let #(customer, _) = sides(atm())
  let #(_, teller) =
    sides(spec.Protocol(
      name: "atm",
      roles: ["Customer", "Teller"],
      initial: "Greeting",
      imports: [],
      spec: spec.Message(
        from: "Customer",
        to: "Teller",
        label: "card",
        // The teller was built expecting a different card type.
        payload: "String",
        then: spec.Loop(
          "session",
          spec.Choice(at: "Customer", to: "Teller", branches: [
            spec.Branch("deposit", "Amount", balance_then_repeat()),
            spec.Branch("quit", "Nil", spec.End),
          ]),
        ),
      ),
    ))

  assert relations.dual(customer, teller)
    == Error(relations.Mismatch(
      left: "Greeting",
      right: "Greeting",
      reason: relations.DifferentPayloads(
        label: "card",
        left: "CardId",
        right: "String",
      ),
    ))
}

pub fn a_branch_the_other_side_cannot_handle_breaks_duality_test() {
  let #(customer, _) = sides(atm_with_transfers())
  let #(_, teller) = sides(atm())

  assert relations.dual(customer, teller)
    == Error(relations.Mismatch(
      left: "Session",
      right: "Session",
      reason: relations.UnmatchedBranch("transfer"),
    ))
}

// EQUIVALENCE

pub fn a_protocol_is_equivalent_to_itself_test() {
  let #(customer, _teller) = sides(atm())

  let assert Ok(_) = relations.equivalent(customer, customer)
}

pub fn renaming_a_loop_does_not_change_the_protocol_test() {
  let #(customer, _) = sides(atm())
  let #(renamed, _) =
    sides(spec.Protocol(
      name: "atm",
      roles: ["Customer", "Teller"],
      initial: "Hello",
      imports: [],
      spec: spec.Message(
        from: "Customer",
        to: "Teller",
        label: "card",
        payload: "CardId",
        then: spec.Loop(
          "round",
          spec.Choice(at: "Customer", to: "Teller", branches: [
            spec.Branch(
              "deposit",
              "Amount",
              spec.Message(
                from: "Teller",
                to: "Customer",
                label: "balance",
                payload: "Amount",
                then: spec.Continue("round"),
              ),
            ),
            spec.Branch("quit", "Nil", spec.End),
          ]),
        ),
      ),
    ))

  // Different state names throughout, same behaviour. Telling those apart is
  // the whole reason to compare behaviour rather than syntax.
  assert graph.state_names(customer) != graph.state_names(renamed)
  let assert Ok(_) = relations.equivalent(customer, renamed)
}

pub fn adding_a_branch_does_change_the_protocol_test() {
  let #(customer, _) = sides(atm())
  let #(wider, _) = sides(atm_with_transfers())

  let assert Error(_) = relations.equivalent(customer, wider)
}

// SUBTYPING
//
// The check to run before changing a published protocol. Which direction is
// safe depends on which side of the choice you are, and getting it backwards
// is exactly the mistake this catches.

pub fn a_participant_may_offer_more_than_it_was_asked_to_test() {
  let #(_, old_teller) = sides(atm())
  let #(_, new_teller) = sides(atm_with_transfers())

  // A teller that also handles transfers still serves every customer written
  // against the old protocol. Being ready for a message nobody sends is free.
  let assert Ok(_) = relations.subtype(new_teller, old_teller)
}

pub fn a_participant_may_not_offer_less_than_it_was_asked_to_test() {
  let #(_, old_teller) = sides(atm())
  let #(_, new_teller) = sides(atm_with_transfers())

  // The other direction strands anybody who sends `transfer`.
  assert relations.subtype(old_teller, new_teller)
    == Error(relations.Mismatch(
      left: "Session",
      right: "Session",
      reason: relations.UnmatchedBranch("transfer"),
    ))
}

pub fn a_participant_may_select_fewer_arms_than_it_was_allowed_test() {
  let #(old_customer, _) = sides(atm())
  let #(new_customer, _) = sides(atm_with_transfers())

  // A customer that never asks for a transfer strands nobody.
  let assert Ok(_) = relations.subtype(old_customer, new_customer)
}

pub fn a_participant_may_not_select_arms_it_was_not_allowed_test() {
  let #(old_customer, _) = sides(atm())
  let #(new_customer, _) = sides(atm_with_transfers())

  // A customer that might ask for a transfer is not safe against a teller that
  // has never heard of one. Same pair of protocols as the teller test above,
  // and the safe direction is the opposite one.
  let assert Error(_) = relations.subtype(new_customer, old_customer)
}

pub fn a_protocol_is_a_subtype_of_itself_test() {
  let #(customer, teller) = sides(atm_with_transfers())

  let assert Ok(_) = relations.subtype(customer, customer)
  let assert Ok(_) = relations.subtype(teller, teller)
}

// REPORTING

pub fn a_mismatch_explains_itself_test() {
  let #(customer, _) = sides(atm_with_transfers())
  let #(_, teller) = sides(atm())
  let assert Error(mismatch) = relations.dual(customer, teller)

  let explained = relations.explain(mismatch)

  assert explained != ""
}

pub fn a_witness_renders_as_the_pairs_it_found_test() {
  let #(customer, teller) = sides(atm())
  let assert Ok(witness) = relations.dual(customer, teller)

  assert relations.render(witness)
    == "Greeting ~ Greeting\nSession ~ Session\nAtBalance ~ AtBalance\nEnded ~ Ended"
}
