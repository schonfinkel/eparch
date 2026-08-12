////
//// The ATM, as a `gen_statem` driven by the protocol.
////
//// This is the paper's Figure 9 (`fn atm(c: Chan<(), Atm>)`) rewritten as an
//// OTP process. The paper's version is a function that owns the channel and
//// blocks on it in a loop. That shape is not available here, and deliberately
//// so: blocking inside a `gen_statem` callback stalls the process, so timeouts
//// stop firing, `sys:get_status/1` hangs, and a supervisor's shutdown goes
//// unanswered. `eparch/protocol_machine` inverts it. Each protocol position
//// becomes a function returning the state to sit in, and the loop is the
//// `gen_statem` receive loop rather than one written here.
////
//// What is preserved is the thing worth preserving. Every position below is
//// checked against the protocol at compile time, and the checks are the same
//// ones the paper's `Chan<E, P>` performs:
////
//// - `pm.accept` only compiles at a position the protocol says is a receive,
////   and only for the payload type it declared.
//// - `pm.transmit` only compiles at a send.
//// - `pm.complete` only compiles at `Done`, so the machine cannot hang up while
////   it still owes the client a message.
//// - the continuation's argument type is *derived from the protocol*, so a
////   handler that returns the wrong next position does not compile. Nothing in
////   this file writes down what comes after `Reporting`; `generated/atm/atm`
////   says it, and the compiler holds this file to it.
////
//// ## Positions, tags and data
////
//// Three things are easy to confuse, so, plainly:
////
//// | | What it is | Where it lives |
//// |---|---|---|
//// | Position | Where the protocol is (`atm.Serving`) | A phantom type, erased at runtime |
//// | Tag | Where `gen_statem` thinks it is (`Serving`) | The `gen_statem` state |
//// | Data | The money (`Amount`) | The `gen_statem` data |
////
//// The tag has to be small and comparable, because `gen_statem` compares state
//// values to decide whether a transition happened, and that decision is what
//// drives state timeouts. Give two positions the same tag and a real move
//// becomes invisible to OTP.
////
//// Anything else a position needs is an ordinary argument to the function that
//// builds it, captured in the handler's closure. `at_assessing` takes the
//// amount asked for that way: it is needed for exactly one decision, and
//// putting it in the machine's data would mean every other position carried a
//// field that is meaningless there.
////
//// ## Every position visited here is generated
////
//// The protocol loops, so it could not have been written as a nested type at
//// all: returning to an earlier position needs a type alias defined in terms of
//// itself, which Gleam rejects outright. `atm.Serving` and the rest are flat
//// names emitted from the specification, and every step goes through
//// `pm.along` with a generated route.
////

import atm/money.{type Amount, type CardId}
import atm/wire.{
  type Wire, Approved, Balance, Card, Declined, Deposit, Dispensed, Proceed,
  Quit, Rejected, Withdraw,
}
import eparch/protocol_machine as pm
import eparch/session/core.{type Channel}
import eparch/state_machine
import generated/atm/atm
import gleam/erlang/process.{type Subject}

/// Where `gen_statem` thinks the machine is.
///
/// One per position, all distinct. They show up in `sys:get_status/1` and in
/// crash reports, which is most of why they are worth naming well.
///
pub type Tag {
  /// Waiting for a card to go in.
  Reading
  /// Deciding whether to accept it.
  Screening
  /// Waiting for the client to choose a transaction.
  Serving
  /// Owing the client a balance.
  Reporting
  /// Deciding whether the account covers a withdrawal.
  Assessing
  /// Done, and about to stop.
  Closing
}

/// The five type parameters of a protocol state, fixed for this machine.
///
/// Worth doing once per protocol. Without it every position function below
/// would repeat `Tag, Amount, Wire, Nil` in its return type, and the one part
/// that differs between them, the position, would be the easiest part to miss.
type Position(protocol) =
  pm.ProtocolState(protocol, Tag, Amount, Wire, Nil)

/// How long the machine will wait at one position before giving up on the
/// client.
///
/// A real cash machine does not hold a session open forever because somebody
/// wandered off, and neither does this. The timer is re-armed on every move, so
/// it measures time spent waiting at a single position rather than the length
/// of the session.
const patience = 30_000

/// Start an ATM holding `balance`, talking to `client`.
///
/// Call this from the process that will be the client. The channel's peer is
/// taken from the caller, which is what ties this machine to that process for
/// the life of the session.
///
/// ## Example
///
/// ```gleam
/// let inbox = process.new_subject()
/// let assert Ok(started) = machine.start(serving: inbox, holding: 500)
/// state_machine.cast(started.ref, wire.Card("4111"))
/// ```
///
pub fn start(
  serving client: Subject(Wire),
  holding balance: Amount,
) -> state_machine.StartResult(Wire) {
  start_noticing(serving: client, holding: balance, noticing: fn(_) { Nil })
}

/// Start an ATM that also reports protocol violations somewhere.
///
/// `noticing` is called whenever a handler answers an event with `pm.reject`,
/// which is the machine saying the client spoke out of turn. Logging it in one
/// place beats logging it at every rejection site, and a machine that quietly
/// swallows violations is a machine nobody can debug.
///
pub fn start_noticing(
  serving client: Subject(Wire),
  holding balance: Amount,
  noticing complain: fn(String) -> Nil,
) -> state_machine.StartResult(Wire) {
  at_awaiting_card(atm.begin(process.self()), balance, client)
  |> pm.new
  |> pm.on_violation(fn(violation) { complain(violation.reason) })
  |> pm.with_timeout(after: patience, sending: Proceed)
  |> pm.start_link
}

// THE POSITIONS
//
// One function per position, in protocol order. Each returns the state to sit
// in while at that position, and each names the position it is for in its own
// signature, so a function wired to the wrong place does not compile.

/// `?[id]`: the card goes in.
///
/// The paper checks the card here too, in the line right after `c.recv()`. The
/// difference is that the check's *result* has to travel to the next position
/// rather than being acted on immediately, because accepting the card and
/// announcing the decision are two protocol steps. It travels as an argument.
fn at_awaiting_card(
  channel: Channel(atm.AwaitingCard, Wire),
  balance: Amount,
  client: Subject(Wire),
) -> Position(atm.AwaitingCard) {
  pm.state(
    tag: Reading,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event {
        state_machine.Cast(Card(id)) ->
          pm.along(at: channel, route: atm.awaiting_card, step: fn(channel) {
            pm.accept(
              at: channel,
              message: id,
              // The next position owes the client an answer and has nothing to
              // wait for, so wake it immediately rather than sitting on a reply
              // the client is expecting.
              actions: [pm.advance_now(Proceed)],
              then: fn(next) {
                at_screening(next, balance, client, approved(id))
              },
            )
          })

        state_machine.Timeout(_, _) -> abandoned(channel)

        _ -> pm.postpone()
      }
    },
  )
}

/// `⊕{ok : ATM', err : ε}`: the machine's turn to decide.
///
/// Both arms are a choice followed by a send, and the generated route performs
/// the choice, so what is left here is an ordinary `transmit`. The `Nil` being
/// transmitted is the branch label: the news is which arm was taken, and
/// `Approved` or `Rejected` is how that arm is spelled on the wire.
fn at_screening(
  channel: Channel(atm.Screening, Wire),
  balance: Amount,
  client: Subject(Wire),
  accept: Bool,
) -> Position(atm.Screening) {
  pm.state(
    tag: Screening,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event, accept {
        state_machine.Cast(Proceed), True ->
          pm.along(at: channel, route: atm.screening_ok, step: fn(channel) {
            pm.transmit(
              at: channel,
              message: Nil,
              actions: [],
              then: fn(_label, next) {
                process.send(client, Approved)
                at_serving(next, balance, client)
              },
            )
          })

        state_machine.Cast(Proceed), False ->
          pm.along(at: channel, route: atm.screening_err, step: fn(channel) {
            pm.transmit(
              at: channel,
              message: Nil,
              actions: [pm.advance_now(Proceed)],
              then: fn(_label, next) {
                process.send(client, Rejected)
                at_ended(next, balance)
              },
            )
          })

        state_machine.Timeout(_, _), _ -> abandoned(channel)

        _, _ -> pm.postpone()
      }
    },
  )
}

/// `µt.&{deposit : …, withdraw : …, quit : ε}`: the head of the loop, and the
/// reason this protocol needed a generator.
///
/// Three arms, and `core` branches two at a time, so the position nests. Each
/// route below walks the whole nest in one step, which is what keeps one arm to
/// one `case` clause here instead of one clause per level. The paper reaches
/// for a macro (`offer!`) at the same point, and prints a caveat with it: its
/// branch order is tied to the nesting, so the arms cannot be reordered. These
/// arms are named rather than counted, so they can.
fn at_serving(
  channel: Channel(atm.Serving, Wire),
  balance: Amount,
  client: Subject(Wire),
) -> Position(atm.Serving) {
  pm.state(
    tag: Serving,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event {
        state_machine.Cast(Deposit(amount)) ->
          pm.along(at: channel, route: atm.serving_deposit, step: fn(channel) {
            pm.accept(
              at: channel,
              message: amount,
              actions: [pm.advance_now(Proceed)],
              then: fn(next) { at_reporting(next, balance + amount, client) },
            )
          })

        state_machine.Cast(Withdraw(amount)) ->
          pm.along(at: channel, route: atm.serving_withdraw, step: fn(channel) {
            pm.accept(
              at: channel,
              message: amount,
              actions: [pm.advance_now(Proceed)],
              then: fn(next) { at_assessing(next, balance, amount, client) },
            )
          })

        state_machine.Cast(Quit) ->
          pm.along(at: channel, route: atm.serving_quit, step: fn(channel) {
            pm.accept(
              at: channel,
              message: Nil,
              actions: [pm.advance_now(Proceed)],
              then: fn(next) { at_ended(next, balance) },
            )
          })

        state_machine.Timeout(_, _) -> abandoned(channel)

        // A second card, from a client that is already in a session. Not early,
        // just wrong: no later position wants it either, so postponing it would
        // leave it in the queue forever. Rejecting keeps the session going and
        // tells whoever is listening why.
        state_machine.Cast(Card(_)) ->
          pm.reject("there is already a card in the machine", [])

        _ -> pm.postpone()
      }
    },
  )
}

/// `![u64]`: the balance after a deposit.
fn at_reporting(
  channel: Channel(atm.Reporting, Wire),
  balance: Amount,
  client: Subject(Wire),
) -> Position(atm.Reporting) {
  pm.state(
    tag: Reporting,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event {
        state_machine.Cast(Proceed) ->
          pm.along(at: channel, route: atm.reporting, step: fn(channel) {
            pm.transmit(
              at: channel,
              message: balance,
              actions: [],
              then: fn(amount, next) {
                // `amount` is the value the protocol just checked, handed back so
                // that what was type-checked is what goes on the wire.
                process.send(client, Balance(amount))
                // Straight back to the head of the loop.
                at_serving(next, balance, client)
              },
            )
          })

        state_machine.Timeout(_, _) -> abandoned(channel)

        _ -> pm.postpone()
      }
    },
  )
}

/// `⊕{ok : t, err : t}`: enough in the account, or not.
///
/// Both arms return to the head of the loop, which is what the paper's two `t`s
/// say. The difference between them is the label, and the label is the whole
/// message.
fn at_assessing(
  channel: Channel(atm.Assessing, Wire),
  balance: Amount,
  wanted: Amount,
  client: Subject(Wire),
) -> Position(atm.Assessing) {
  pm.state(
    tag: Assessing,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event, wanted <= balance {
        state_machine.Cast(Proceed), True ->
          pm.along(at: channel, route: atm.assessing_ok, step: fn(channel) {
            pm.transmit(
              at: channel,
              message: Nil,
              actions: [],
              then: fn(_label, next) {
                process.send(client, Dispensed)
                at_serving(next, balance - wanted, client)
              },
            )
          })

        state_machine.Cast(Proceed), False ->
          pm.along(at: channel, route: atm.assessing_err, step: fn(channel) {
            pm.transmit(
              at: channel,
              message: Nil,
              actions: [],
              then: fn(_label, next) {
                process.send(client, Declined)
                at_serving(next, balance, client)
              },
            )
          })

        state_machine.Timeout(_, _), _ -> abandoned(channel)

        _, _ -> pm.postpone()
      }
    },
  )
}

/// `ε`: nothing is owed in either direction.
///
/// `pm.complete` is the only way out of here, and it only compiles at `Done`.
/// The machine stops normally, so a supervisor treats this as a job finished
/// rather than a process that fell over.
fn at_ended(
  channel: Channel(atm.Ended, Wire),
  balance: Amount,
) -> Position(atm.Ended) {
  pm.state(
    tag: Closing,
    at: channel,
    data: balance,
    handler: fn(event, channel, _balance) {
      case event {
        state_machine.Cast(Proceed) ->
          pm.along(at: channel, route: atm.ended, step: fn(channel) {
            pm.complete(at: channel, actions: [])
          })

        state_machine.Timeout(_, _) -> abandoned(channel)

        _ -> pm.postpone()
      }
    },
  )
}

/// Give up on a client that has stopped talking.
///
/// Valid at every position, which is exactly why it is not `pm.complete`:
/// `complete` proves the protocol was finished, and this proves nothing. The
/// machine stops normally because a client wandering off is not a fault.
fn abandoned(
  channel: Channel(protocol, Wire),
) -> pm.ProtocolTransition(protocol, Tag, Amount, Wire, Nil) {
  pm.fail(at: channel, reason: process.Normal, actions: [])
}

/// Whether the card is one this machine will talk to.
///
/// The paper's `approved(id)`, with the same amount of banking behind it.
fn approved(card: CardId) -> Bool {
  card != ""
}
