////
//// The client side, walked by hand.
////
//// The paper's Figures 11 and 12, which are the other half of its ATM example:
//// two small client programs driving a channel directly rather than through
//// anything resembling a framework. They are worth reproducing because they are
//// where session typing is easiest to *see*. Every line below changes the
//// channel's position, and the compiler agreed to every one of them.
////
//// ## What the paper writes, and what this writes
////
//// Rust consumes the channel on every step, so the paper chains method calls
//// and rebinds:
////
//// ```rust
//// let (c, new_bal) = c.sel1().send(100).recv();
//// c.zero().sel2().sel2().close();
//// ```
////
//// Gleam has no move semantics, so a channel is shadowed rather than consumed.
//// The steps are the same steps:
////
//// ```gleam
//// let #(amount, channel) = core.send(client.serving_deposit(channel), 100)
//// ```
////
//// The difference the shadowing makes is honest and worth stating: nothing here
//// stops you keeping the old binding and stepping it twice. What the types rule
//// out is reaching a position you have no proof of, not reusing a proof you
//// already hold. The discipline the paper gets from affine types is the one
//// thing this encoding does not have, and the way to get it back is to keep the
//// channel somewhere that is replaced rather than copied, which is what
//// `atm/machine` does by keeping it in a `gen_statem`'s data.
////
//// ## `zero()`, `sel2()`, and why there are none here
////
//// The paper's clients navigate with positional combinators. `sel1()` takes the
//// left arm, `sel2()` the right, `zero()` returns to the innermost `Rec`, and
//// reaching the third arm of a three-armed choice means `sel2().sel2()`. It
//// notes the cost itself: extending a protocol "might require users to take
//// into account parts of the protocol that they are not interested in", and
//// `skip3()` exists to make the chains shorter rather than to make them
//// unnecessary.
////
//// Here the arms have names, because the generator knew them:
//// `client.serving_quit` is the `quit` arm however many arms are added before
//// it. Returning to the head of the loop is not an operation at all: a step
//// that the protocol says loops hands back a channel already at
//// `client.Serving`, so `zero()` has nothing to correspond to. Add a branch to
//// the specification and this file keeps compiling unless it genuinely needs to
//// change.
////

import atm/money.{type Amount, type CardId}
import atm/wire.{type Wire}
import eparch/session/core.{type Channel}
import eparch/state_machine
import generated/atm/client
import gleam/erlang/process.{type Subject}
import gleam/result

/// Everything that can go wrong that is not the protocol's fault.
///
pub type Trouble {
  /// The machine took the `err` arm after reading the card.
  CardRejected
  /// The machine stopped talking.
  NoAnswer
  /// The machine said something the protocol does not allow at this point.
  ///
  /// Reaching this means the peer is not speaking the protocol, which the type
  /// system cannot rule out: it checks this program against the protocol, and
  /// says nothing about a process on the other end that was written against
  /// something else. Checking the peer too is what `relations.dual` is for, and
  /// it is done once at specification time rather than per message.
  Unexpected(Wire)
}

/// What became of a withdrawal.
///
pub type Withdrawal {
  /// The `ok` arm: the money came out.
  Paid(cash: Amount)
  /// The `err` arm: it did not, and the fallback deposit went in instead.
  Overdrawn(balance: Amount)
}

/// How long to wait for the machine before giving up on it.
const patience = 5000

/// The paper's Figure 11: pay in an amount, read the new balance, leave.
///
/// ## Example
///
/// ```gleam
/// let inbox = process.new_subject()
/// let assert Ok(atm) = machine.start(serving: inbox, holding: 0)
/// let assert Ok(120) = client.deposit(120, at: atm, from: inbox, with: "4111")
/// ```
///
pub fn deposit(
  amount: Amount,
  at atm: state_machine.Started(Wire),
  from inbox: Subject(Wire),
  with card: CardId,
) -> Result(Amount, Trouble) {
  use channel <- arrive(atm, inbox, card)

  use #(balance, channel) <- result.try(pay_in(amount, channel, atm, inbox))
  use Nil <- result.map(leave(channel, atm))

  balance
}

/// The paper's Figure 12: ask for cash, and if the machine declines, pay
/// `fallback` in instead and read the balance. Either way, leave.
///
/// The interesting line is the one that does not appear. Both arms of the
/// machine's answer return to the head of the loop, so both continuations have
/// the same type, so the `case` below needs no reconciliation between them. The
/// protocol arranged that, not this function.
///
pub fn withdraw(
  amount: Amount,
  at atm: state_machine.Started(Wire),
  from inbox: Subject(Wire),
  with card: CardId,
  paying fallback: Amount,
) -> Result(Withdrawal, Trouble) {
  use channel <- arrive(atm, inbox, card)

  // `serving_withdraw` is the second of three arms. The paper spells this
  // `sel2().sel1()`.
  let #(wanted, channel) = core.send(client.serving_withdraw(channel), amount)
  state_machine.cast(atm.ref, wire.Withdraw(wanted))

  use answer <- result.try(listen(inbox, channel))
  case answer {
    wire.Dispensed -> {
      let channel = core.receive(client.assessing_ok(channel), Nil)
      use Nil <- result.map(leave(channel, atm))
      Paid(cash: wanted)
    }

    wire.Declined -> {
      let channel = core.receive(client.assessing_err(channel), Nil)
      use #(balance, channel) <- result.try(pay_in(
        fallback,
        channel,
        atm,
        inbox,
      ))
      use Nil <- result.map(leave(channel, atm))
      Overdrawn(balance:)
    }

    other -> lost(channel, other)
  }
}

// THE PIECES BOTH CLIENTS SHARE

/// `![id]; &{ok : …, err : ε}`: put the card in and see whether the machine
/// wants to talk.
///
/// Takes a continuation rather than returning the channel, because the two arms
/// of the machine's answer lead to positions of *different types*, and a
/// function can only return one. Handing the good arm to a continuation is what
/// keeps the bad arm's `Ended` from having to be reconciled with it. This is
/// the same reason `eparch/protocol_machine`'s transitions are
/// continuation-passing, met from the other side.
fn arrive(
  atm: state_machine.Started(Wire),
  inbox: Subject(Wire),
  card: CardId,
  then serve: fn(Channel(client.Serving, Wire)) -> Result(a, Trouble),
) -> Result(a, Trouble) {
  let channel = client.begin(atm.pid)

  let #(card, channel) = core.send(client.awaiting_card(channel), card)
  state_machine.cast(atm.ref, wire.Card(card))

  use answer <- result.try(listen(inbox, channel))
  case answer {
    wire.Approved -> serve(core.receive(client.screening_ok(channel), Nil))

    wire.Rejected -> {
      let channel = core.receive(client.screening_err(channel), Nil)
      // `finish` only compiles at `Done`. Ending here is allowed because the
      // protocol says the session really is over, not because this side has
      // had enough.
      let _ = core.finish(client.ended(channel))
      Error(CardRejected)
    }

    other -> lost(channel, other)
  }
}

/// `⊕deposit; ![u64]; ?[u64]; t`: pay in, and read what the machine says the
/// balance is now.
fn pay_in(
  amount: Amount,
  channel: Channel(client.Serving, Wire),
  atm: state_machine.Started(Wire),
  inbox: Subject(Wire),
) -> Result(#(Amount, Channel(client.Serving, Wire)), Trouble) {
  let #(amount, channel) = core.send(client.serving_deposit(channel), amount)
  state_machine.cast(atm.ref, wire.Deposit(amount))

  use answer <- result.try(listen(inbox, channel))
  case answer {
    wire.Balance(balance) -> {
      // The balance is checked against the protocol on the way in, which is
      // what makes it an `Amount` here rather than a message that might be one.
      let channel = core.receive(client.reporting(channel), balance)
      Ok(#(balance, channel))
    }

    other -> lost(channel, other)
  }
}

/// `⊕quit; ε`: the third arm, and the end of the session.
///
/// The paper writes this `zero().sel2().sel2().close()`, and adding a branch to
/// the protocol turns it into `sel2().sel2().sel2()`. Here it stays
/// `serving_quit` however many arms there are.
fn leave(
  channel: Channel(client.Serving, Wire),
  atm: state_machine.Started(Wire),
) -> Result(Nil, Trouble) {
  let #(Nil, channel) = core.send(client.serving_quit(channel), Nil)
  state_machine.cast(atm.ref, wire.Quit)

  let _ = core.finish(client.ended(channel))
  Ok(Nil)
}

/// Wait for the machine to say something.
///
/// A channel is passed in only so that a machine that has gone quiet does not
/// leave a monitor behind. Nothing about the position is inspected, which is
/// why it is free in the signature.
fn listen(
  inbox: Subject(Wire),
  channel: Channel(protocol, Wire),
) -> Result(Wire, Trouble) {
  case process.receive(inbox, within: patience) {
    Ok(message) -> Ok(message)
    Error(Nil) -> {
      let _ = core.close(channel)
      Error(NoAnswer)
    }
  }
}

/// Give up on a machine that is not speaking the protocol.
///
/// `core.close` rather than `core.finish`, from a position that is not `Done`.
/// The two are named differently on purpose: `finish` is a claim that the
/// conversation ended, and this is a claim that it stopped.
fn lost(channel: Channel(protocol, Wire), said: Wire) -> Result(a, Trouble) {
  let _ = core.close(channel)
  Error(Unexpected(said))
}
