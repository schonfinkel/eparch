////
//// Tests for the ATM example.
////
//// They come in three groups, and the middle one is the unusual one:
////
//// 1. **The sessions run.** Both of the paper's client programs, against a real
////    `gen_statem`, end to end.
//// 2. **The specification is sound.** Duality between the two projected views,
////    and subtyping between the protocol and the extension of it in
////    `protocol.atm_with_balance`. These are questions about the *protocol*, and
////    they are answered without starting a process or sending a message.
//// 3. **The committed generated modules still match.** What
////    `gleam run -m generate check` does, so that `gleam test` catches it too.
////
//// What is *not* here is a test that a protocol violation fails to compile.
//// gleeunit cannot express "this must not compile", so the compile-time
//// rejections are in the README, each with the compiler's own words under it,
//// and they are checked by hand against the current compiler.
////

import atm/client
import atm/machine
import atm/protocol
import atm/wire.{type Wire}
import eparch/protocol/emit
import eparch/protocol/graph
import eparch/protocol/relations
import eparch/session/core.{type Channel}
import eparch/state_machine
import generate
import generated/atm/client as route
import gleam/erlang/process.{type Subject}
import gleam/list
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// THE SESSIONS RUN

pub fn a_deposit_reads_back_the_new_balance_test() {
  let inbox = process.new_subject()
  let assert Ok(atm) = machine.start(serving: inbox, holding: 500)

  assert client.deposit(120, at: atm, from: inbox, with: "4111") == Ok(620)
}

pub fn a_withdrawal_the_account_covers_is_paid_test() {
  let inbox = process.new_subject()
  let assert Ok(atm) = machine.start(serving: inbox, holding: 500)

  let asked =
    client.withdraw(200, at: atm, from: inbox, with: "4111", paying: 50)

  assert asked == Ok(client.Paid(cash: 200))
}

pub fn a_withdrawal_the_account_does_not_cover_falls_back_test() {
  let inbox = process.new_subject()
  let assert Ok(atm) = machine.start(serving: inbox, holding: 30)

  // The `err` arm returns to the head of the loop rather than ending the
  // session, so the fallback deposit happens over the same channel.
  let asked =
    client.withdraw(200, at: atm, from: inbox, with: "4111", paying: 50)

  assert asked == Ok(client.Overdrawn(balance: 80))
}

pub fn a_rejected_card_ends_the_session_test() {
  let inbox = process.new_subject()
  let assert Ok(atm) = machine.start(serving: inbox, holding: 500)
  let monitor = process.monitor(atm.pid)

  assert client.deposit(120, at: atm, from: inbox, with: "")
    == Error(client.CardRejected)

  // `ε` on the machine's side too: it stops, and stops normally, so a
  // supervisor reads it as a job finished rather than a process that fell over.
  assert died(monitor) == process.Normal
}

pub fn a_finished_session_stops_the_machine_test() {
  let inbox = process.new_subject()
  let assert Ok(atm) = machine.start(serving: inbox, holding: 500)
  let monitor = process.monitor(atm.pid)

  let assert Ok(_) = client.deposit(120, at: atm, from: inbox, with: "4111")

  assert died(monitor) == process.Normal
}

/// The loop, gone round ten times.
///
/// This is the protocol no nested type could have expressed: returning to an
/// earlier position needs a type alias defined in terms of itself, which Gleam
/// rejects outright. It is also the reason the fold below type-checks at all.
/// Every trip round leaves the channel at `route.Serving`, the same type it
/// started at, so the accumulator has one type and an ordinary `list.fold` can
/// carry it.
pub fn the_loop_goes_round_as_many_times_as_it_is_asked_to_test() {
  let inbox = process.new_subject()
  let assert Ok(atm) = machine.start(serving: inbox, holding: 0)

  let channel = arrive(atm, inbox, "4111")

  let #(balance, channel) =
    list.fold(list.repeat(Nil, 10), #(0, channel), fn(carried, _) {
      let #(_, channel) = carried
      let #(amount, channel) = core.send(route.serving_deposit(channel), 10)
      state_machine.cast(atm.ref, wire.Deposit(amount))

      let assert Ok(wire.Balance(balance)) =
        process.receive(inbox, within: 1000)
      #(balance, core.receive(route.reporting(channel), balance))
    })

  assert balance == 100

  let #(Nil, channel) = core.send(route.serving_quit(channel), Nil)
  state_machine.cast(atm.ref, wire.Quit)

  assert core.finish(route.ended(channel)).protocol_name == "atm"
}

/// A peer that speaks out of turn is refused, and the session carries on.
///
/// Nothing here goes through a channel, because there is no position that
/// allows a second card: this is what a process written against some other
/// protocol looks like from the machine's side. The type system checks each
/// participant against the protocol and can say nothing about a stranger, so
/// the runtime has to have an answer, and `pm.reject` is it. Postponing would
/// be worse than useless: no later position wants a second card either, so the
/// event would sit in the queue forever.
pub fn a_client_speaking_out_of_turn_is_refused_test() {
  let complaints = process.new_subject()
  let inbox = process.new_subject()
  let assert Ok(atm) =
    machine.start_noticing(serving: inbox, holding: 500, noticing: fn(reason) {
      process.send(complaints, reason)
    })

  let channel = arrive(atm, inbox, "4111")

  state_machine.cast(atm.ref, wire.Card("9999"))

  assert process.receive(complaints, within: 1000)
    == Ok("there is already a card in the machine")

  // Still at `Serving`, and still working.
  let #(amount, channel) = core.send(route.serving_deposit(channel), 10)
  state_machine.cast(atm.ref, wire.Deposit(amount))

  assert process.receive(inbox, within: 1000) == Ok(wire.Balance(510))

  let channel = core.receive(route.reporting(channel), 510)
  let #(Nil, channel) = core.send(route.serving_quit(channel), Nil)
  state_machine.cast(atm.ref, wire.Quit)
  let _ = core.finish(route.ended(channel))
}

// THE SPECIFICATION IS SOUND

pub fn the_protocol_is_well_formed_test() {
  let assert Ok([client, atm]) = graph.compile(protocol.atm())

  assert client.role == "Client"
  assert atm.role == "Atm"
}

/// The paper derives the client's type from the ATM's with
/// `<Atm as HasDual>::Dual`, and duality is what makes that derivation safe.
/// Here both views are projected from one global specification, so duality is
/// something to *check* rather than something to construct.
///
/// It is checked over the state graphs rather than by building a witness value,
/// and it has to be: this protocol loops, and a finite value cannot witness an
/// infinite unfolding. `eparch/session/duality` is the tool for a protocol
/// written as a nested type; `relations.dual` is the tool for one that repeats.
pub fn the_two_generated_views_are_duals_test() {
  let assert Ok([client, atm]) = graph.compile(protocol.atm())
  let assert Ok(_) = relations.dual(client, atm)
}

/// The paper's §4.3, answered rather than argued.
///
/// Adding an arm to a choice is safe in one direction and unsafe in the other,
/// and which is which depends on who decides. The machine *offers* the arms, so
/// offering one more costs nothing: being ready for a message nobody sends is
/// free. The client *selects*, so a client that knows about the new arm may
/// send something an old machine cannot handle.
pub fn adding_a_branch_keeps_old_clients_working_test() {
  let assert Ok([old_client, old_atm]) = graph.compile(protocol.atm())
  let assert Ok([new_client, new_atm]) =
    graph.compile(protocol.atm_with_balance())

  // A new machine can stand in for an old one: it offers more.
  let assert Ok(_) = relations.subtype(new_atm, old_atm)

  // An old client can stand in for a new one: it selects fewer.
  let assert Ok(_) = relations.subtype(old_client, new_client)

  // Neither of the reverses holds. An old machine cannot answer a `balance`
  // request, and a new client is entitled to make one.
  let assert Error(_) = relations.subtype(old_atm, new_atm)
  let assert Error(_) = relations.subtype(new_client, old_client)
}

/// An edit that changes nothing is a different thing from an edit that changes
/// something, and bisimulation is what tells them apart.
pub fn the_extension_is_not_the_same_protocol_test() {
  let assert Ok([_, old_atm]) = graph.compile(protocol.atm())
  let assert Ok([_, new_atm]) = graph.compile(protocol.atm_with_balance())

  let assert Ok(_) = relations.equivalent(old_atm, old_atm)
  let assert Error(_) = relations.equivalent(old_atm, new_atm)
}

// THE COMMITTED GENERATED MODULES STILL MATCH

pub fn the_generated_modules_on_disk_are_up_to_date_test() {
  let assert Ok(wanted) = emit.modules(protocol.atm(), under: generate.prefix)

  assert list.map(emit.review(wanted, against: generate.on_disk), emit.describe)
    == ["generated/atm/client: up to date", "generated/atm/atm: up to date"]
}

// HELPERS

/// Put a card in and get past the screening choice, for a test that is
/// interested in what comes after it.
fn arrive(
  atm: state_machine.Started(Wire),
  inbox: Subject(Wire),
  card: String,
) -> Channel(route.Serving, Wire) {
  let channel = route.begin(atm.pid)
  let #(card, channel) = core.send(route.awaiting_card(channel), card)
  state_machine.cast(atm.ref, wire.Card(card))

  let assert Ok(wire.Approved) = process.receive(inbox, within: 1000)
  core.receive(route.screening_ok(channel), Nil)
}

/// Wait for a monitored process to go, and say why it went.
fn died(monitor: process.Monitor) -> process.ExitReason {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  let assert Ok(process.ProcessDown(reason:, ..)) =
    process.selector_receive(from: selector, within: 1000)

  reason
}
