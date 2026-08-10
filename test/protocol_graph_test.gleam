////
//// Tests for checking a specification and projecting it onto participants.
////
//// Unlike the `session/core` tests, nothing here is a compile-time guarantee:
//// a specification is a value, so everything it gets wrong is caught at run
//// time by the generator. That makes these tests the whole safety net for this
//// layer, which is why the rejections get as much attention as the successes.
////
//// The two that matter most are `Unmergeable`, which is the multiparty
//// well-formedness condition, and the loop tests, which are the reason this
//// layer exists at all.
////

import eparch/protocol/graph
import eparch/protocol/spec
import gleam/list

// PROTOCOLS UNDER TEST

/// Two participants, a repeat, and a way out of it.
fn atm() -> spec.Protocol {
  spec.Protocol(
    name: "atm",
    roles: ["Customer", "Teller"],
    initial: "Greeting",
    imports: ["import atm/money.{type Amount, type CardId}"],
    spec: spec.Message(
      from: "Customer",
      to: "Teller",
      label: "card",
      payload: "CardId",
      then: spec.Loop(
        "session",
        spec.Choice(at: "Customer", to: "Teller", branches: [
          spec.Branch(
            "deposit",
            "Amount",
            spec.Message(
              from: "Teller",
              to: "Customer",
              label: "balance",
              payload: "Amount",
              then: spec.Continue("session"),
            ),
          ),
          spec.Branch("quit", "Nil", spec.End),
        ]),
      ),
    ),
  )
}

/// Three participants, where one is never told how the decision went.
fn authentication() -> spec.Protocol {
  spec.Protocol(
    name: "authentication",
    roles: ["Client", "Server", "Auth"],
    initial: "LoggingIn",
    imports: [],
    spec: spec.Message(
      from: "Client",
      to: "Server",
      label: "login",
      payload: "Credentials",
      then: spec.Message(
        from: "Server",
        to: "Auth",
        label: "verify",
        payload: "Credentials",
        then: spec.Choice(at: "Auth", to: "Server", branches: [
          spec.Branch(
            "granted",
            "Token",
            spec.Message("Server", "Client", "welcome", "Token", spec.End),
          ),
          spec.Branch(
            "denied",
            "Nil",
            spec.Message("Server", "Client", "refused", "Nil", spec.End),
          ),
        ]),
      ),
    ),
  )
}

fn two_party(body: spec.Spec) -> spec.Protocol {
  spec.Protocol(
    name: "example",
    roles: ["A", "B"],
    initial: "Start",
    imports: [],
    spec: body,
  )
}

fn tell(then: spec.Spec) -> spec.Spec {
  spec.Message(from: "A", to: "B", label: "x", payload: "Nil", then:)
}

// PROJECTION

pub fn both_participants_get_a_view_test() {
  let assert Ok([customer, teller]) = graph.compile(atm())

  assert customer.role == "Customer"
  assert teller.role == "Teller"
  assert customer.initial == "Greeting"
  assert teller.initial == "Greeting"
}

pub fn a_message_is_a_send_for_one_side_and_a_receive_for_the_other_test() {
  let assert Ok([customer, teller]) = graph.compile(atm())

  let assert Ok(graph.State(action: sending, ..)) =
    graph.state(customer, "Greeting")
  let assert Ok(graph.State(action: receiving, ..)) =
    graph.state(teller, "Greeting")

  assert sending
    == graph.Sends(
      to: "Teller",
      label: "card",
      payload: "CardId",
      next: "Session",
    )
  assert receiving
    == graph.Receives(
      from: "Customer",
      label: "card",
      payload: "CardId",
      next: "Session",
    )
}

pub fn a_choice_is_internal_for_one_side_and_external_for_the_other_test() {
  let assert Ok([customer, teller]) = graph.compile(atm())

  let assert Ok(graph.State(action: graph.Selects(to:, arms: chosen), ..)) =
    graph.state(customer, "Session")
  let assert Ok(graph.State(action: graph.Offers(from:, arms: offered), ..)) =
    graph.state(teller, "Session")

  assert to == "Teller"
  assert from == "Customer"
  // The same arms on both sides, which is what stops one participant planning
  // for a branch the other cannot take.
  assert list.map(chosen, fn(arm) { arm.label }) == ["deposit", "quit"]
  assert list.map(offered, fn(arm) { arm.label }) == ["deposit", "quit"]
}

// LOOPS
//
// The whole reason this layer exists. A repeating protocol cannot be a nested
// type, so it becomes an edge back to a state that already exists.

pub fn a_loop_becomes_an_edge_back_to_an_earlier_state_test() {
  let assert Ok([customer, ..]) = graph.compile(atm())

  let assert Ok(graph.State(action: graph.Receives(next:, ..), ..)) =
    graph.state(customer, "AtBalance")

  // Not a copy of the loop body, and not a fresh state. The same one.
  assert next == "Session"
  assert graph.state_names(customer)
    == ["Greeting", "Session", "AtBalance", "Ended"]
}

pub fn every_branch_ends_in_the_one_terminal_state_test() {
  let assert Ok([customer, ..]) = graph.compile(atm())

  let terminals =
    customer.states
    |> list.filter(fn(state) { state.action == graph.Done })
    |> list.map(fn(state) { state.name })

  assert terminals == ["Ended"]
}

pub fn a_loop_that_spins_without_anybody_speaking_is_rejected_test() {
  let protocol = two_party(spec.Loop("l", spec.At("Spin", spec.Continue("l"))))

  assert graph.compile(protocol) == Error(graph.UnguardedRecursion("l"))
}

pub fn a_loop_a_participant_sits_out_is_rejected_test() {
  let protocol =
    spec.Protocol(
      name: "example",
      roles: ["A", "B", "C"],
      initial: "Start",
      imports: [],
      spec: spec.Message(
        "A",
        "B",
        "open",
        "Nil",
        spec.Loop("chatter", tell(spec.Continue("chatter"))),
      ),
    )

  // A and B project. C has nothing to do inside the loop, so it has no state
  // to come back to and no way of telling the protocol went round again.
  assert graph.compile(protocol) == Error(graph.IdleLoop("C", "chatter"))
}

// MERGING
//
// A participant that is not told which arm was taken has to behave the same
// way either way. Whether it can is the multiparty well-formedness condition.

pub fn a_participant_not_told_the_decision_is_ready_for_either_message_test() {
  let assert Ok([client, ..]) = graph.compile(authentication())

  let assert Ok(graph.State(action: graph.Sends(next: merged, ..), ..)) =
    graph.state(client, client.initial)
  let assert Ok(graph.State(action: graph.Offers(from:, arms:), ..)) =
    graph.state(client, merged)

  // The client is never told how the authentication went. It does not need to
  // be: it only has to be ready for either message that can follow, which is
  // one external choice over both.
  assert from == "Server"
  assert list.map(arms, fn(arm) { #(arm.label, arm.payload) })
    == [#("welcome", "Token"), #("refused", "Nil")]
}

pub fn merging_leaves_no_state_behind_test() {
  let assert Ok([client, ..]) = graph.compile(authentication())

  // The per-arm views the merge was built from are superseded by it. Keeping
  // them would emit markers no generated function can reach.
  assert graph.state_names(client) == ["LoggingIn", "Merged", "Ended"]
}

pub fn the_deciding_participant_selects_test() {
  let assert Ok([_client, _server, auth]) = graph.compile(authentication())

  let assert Ok(graph.State(action: graph.Selects(to:, arms:), ..)) =
    graph.state(auth, "Decision")

  assert to == "Server"
  assert list.map(arms, fn(arm) { arm.label }) == ["granted", "denied"]
}

pub fn a_participant_that_would_have_to_guess_is_rejected_test() {
  let protocol =
    spec.Protocol(
      name: "shop",
      roles: ["Client", "Server", "Bank"],
      initial: "Browsing",
      imports: [],
      spec: spec.Choice(at: "Client", to: "Server", branches: [
        spec.Branch(
          "buy",
          "Item",
          spec.Message("Server", "Bank", "charge", "Money", spec.End),
        ),
        spec.Branch(
          "browse",
          "Nil",
          spec.Message("Bank", "Server", "rate", "Money", spec.End),
        ),
      ]),
    )

  // The bank would have to receive in one arm and send in the other, and it is
  // never told which. No amount of merging fixes that; routing the decision
  // through the bank does.
  let assert Error(graph.Unmergeable(role: "Bank", ..)) =
    graph.compile(protocol)
}

pub fn a_participant_that_never_speaks_is_rejected_test() {
  let protocol =
    spec.Protocol(
      name: "example",
      roles: ["A", "B", "C"],
      initial: "Start",
      imports: [],
      spec: tell(spec.End),
    )

  assert graph.compile(protocol) == Error(graph.Uninvolved("C"))
}

// CONTACT POINTS
//
// Erased before anything is emitted, but checked on their own first, so a
// protocol that demands a guarantee nothing established is rejected before it
// is ever composed with anything.

pub fn a_requirement_nothing_established_is_rejected_test() {
  let protocol = two_party(spec.Require("pin", tell(spec.End)))

  assert graph.compile(protocol) == Error(graph.UnmetRequirement("pin"))
}

pub fn a_requirement_survives_being_met_test() {
  // Non-linear: one assertion covers any number of requirements, which is what
  // a PIN checked once at the start of a session is.
  let protocol =
    two_party(spec.Assert(
      "pin",
      spec.Require("pin", tell(spec.Require("pin", spec.End))),
    ))

  let assert Ok(_) = graph.compile(protocol)
}

pub fn consuming_a_guarantee_spends_it_test() {
  // Linear: a one-time code covers exactly one payment.
  let protocol =
    two_party(spec.Assert(
      "tan",
      spec.Consume("tan", tell(spec.Consume("tan", spec.End))),
    ))

  assert graph.compile(protocol) == Error(graph.UnmetRequirement("tan"))
}

pub fn asserting_over_a_live_assertion_is_rejected_test() {
  let protocol =
    two_party(spec.Assert("pin", spec.Assert("pin", tell(spec.End))))

  assert graph.compile(protocol) == Error(graph.DuplicateAssertion("pin"))
}

pub fn a_loop_must_end_holding_what_it_began_with_test() {
  // The second time round starts where the first one did, so a loop that
  // leaves an extra guarantee behind is not the protocol it claims to be.
  let protocol =
    two_party(spec.Loop("l", spec.Assert("pin", tell(spec.Continue("l")))))

  assert graph.compile(protocol) == Error(graph.UnbalancedLoop("l", ["pin"]))
}

pub fn contact_points_leave_no_trace_in_the_projection_test() {
  let plain = two_party(tell(spec.End))
  let annotated =
    two_party(spec.Assert("pin", spec.Require("pin", tell(spec.End))))

  assert graph.compile(annotated) == graph.compile(plain)
}

// SPECIFICATION ERRORS

pub fn a_protocol_needs_two_participants_test() {
  let protocol =
    spec.Protocol(
      name: "example",
      roles: ["A"],
      initial: "Start",
      imports: [],
      spec: spec.End,
    )

  assert graph.compile(protocol) == Error(graph.TooFewRoles(1))
}

pub fn a_participant_cannot_be_named_twice_test() {
  let protocol =
    spec.Protocol(
      name: "example",
      roles: ["A", "B", "A"],
      initial: "Start",
      imports: [],
      spec: tell(spec.End),
    )

  assert graph.compile(protocol) == Error(graph.DuplicateRole("A"))
}

pub fn a_message_to_a_stranger_is_rejected_test() {
  let protocol = two_party(spec.Message("A", "Z", "x", "Nil", spec.End))

  assert graph.compile(protocol) == Error(graph.UnknownRole("Z", "x"))
}

pub fn a_message_to_oneself_is_rejected_test() {
  let protocol = two_party(spec.Message("A", "A", "x", "Nil", spec.End))

  assert graph.compile(protocol) == Error(graph.SelfAddressed("A", "x"))
}

pub fn a_choice_with_one_arm_is_rejected_test() {
  let protocol =
    two_party(
      spec.Choice(at: "A", to: "B", branches: [
        spec.Branch("only", "Nil", spec.End),
      ]),
    )

  assert graph.compile(protocol) == Error(graph.DegenerateChoice("A", 1))
}

pub fn two_arms_with_one_label_are_rejected_test() {
  let protocol =
    two_party(
      spec.Choice(at: "A", to: "B", branches: [
        spec.Branch("go", "Nil", spec.End),
        spec.Branch("go", "Int", spec.End),
      ]),
    )

  assert graph.compile(protocol) == Error(graph.AmbiguousArms("A", "go"))
}

pub fn continuing_a_loop_that_is_not_there_is_rejected_test() {
  let protocol = two_party(tell(spec.Continue("nowhere")))

  assert graph.compile(protocol) == Error(graph.UnboundContinue("nowhere"))
}

pub fn a_loop_inside_a_loop_of_the_same_name_is_rejected_test() {
  let protocol =
    two_party(spec.Loop("l", tell(spec.Loop("l", tell(spec.Continue("l"))))))

  assert graph.compile(protocol) == Error(graph.ShadowedLoop("l"))
}

// STRUCTURAL INVARIANTS
//
// True of every graph the projector produces, so worth stating once rather
// than re-checking per protocol.

pub fn every_edge_points_at_a_state_that_exists_test() {
  let assert Ok(graphs) = list.try_map([atm(), authentication()], graph.compile)

  list.each(list.flatten(graphs), fn(g) {
    let names = graph.state_names(g)
    assert list.contains(names, g.initial)

    list.each(g.states, fn(state) {
      list.each(graph.successors(state), fn(next) {
        assert list.contains(names, next)
      })
    })
  })
}

pub fn state_names_can_be_gleam_type_names_test() {
  // Loop names are written in snake case like any other Gleam identifier, and
  // come out as type names, because that is what the emitter needs them to be.
  let assert Ok([customer, ..]) = graph.compile(atm())

  assert list.contains(graph.state_names(customer), "Session")
}

pub fn errors_describe_themselves_test() {
  let described =
    graph.describe(graph.Unmergeable(role: "Bank", states: ["A", "B"]))

  assert described != ""
}
