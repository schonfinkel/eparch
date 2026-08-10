////
//// The `Customer` view of the `atm` protocol, written by
//// `eparch/protocol/emit`.
////
//// Edits here are lost the next time it is generated. Change the specification
//// instead.
////
//// Each position below is an uninhabited type. The function named after it
//// unfolds it into the `eparch/session/core` shape the protocol says it has,
//// one step deep, and everything after that is an ordinary `core` or
//// `eparch/protocol_machine` call.
////

import atm_protocol.{type Amount, type CardId}
import eparch/session/core.{type Channel}
import gleam/erlang/process.{type Pid}

// POSITIONS

/// Send `card` to `Teller`, carrying `CardId`, then continue at `Session`.
///
pub type Greeting

/// Pick one arm and tell `Teller` which:
///
/// - `deposit` carrying `Amount`, then `AtBalance`
/// - `withdraw` carrying `Amount`, then `AtCash`
/// - `quit` carrying `Nil`, then `Ended`
///
pub type Session

/// The arms of `Session` that are still open once the earlier ones have been
/// ruled out.
///
/// - `withdraw` carrying `Amount`, then `AtCash`
/// - `quit` carrying `Nil`, then `Ended`
///
pub type SessionOtherwise

/// Accept `balance` from `Teller`, carrying `Amount`, then continue at
/// `Session`.
///
pub type AtBalance

/// Accept `cash` from `Teller`, carrying `Amount`, then continue at `Session`.
///
pub type AtCash

/// Nothing is owed in either direction. A channel here can be closed with
/// `core.finish`, and nothing else.
///
pub type Ended

// OPENING

/// Open a channel to `peer` at the start of the protocol.
///
/// No monitor is installed. Call `core.watch` from the process that will own
/// the channel if this side needs to see the peer die.
///
pub fn begin(peer: Pid) -> Channel(Greeting, msg) {
  core.begin(peer, protocol: "atm")
}

// UNFOLDING

/// Send `card` to `Teller`, carrying `CardId`, then continue at `Session`.
///
pub fn greeting(
  channel: Channel(Greeting, msg),
) -> Channel(core.Send(CardId, Session), msg) {
  core.unchecked_position(channel)
}

/// Pick one arm and tell `Teller` which:
///
/// - `deposit` carrying `Amount`, then `AtBalance`
/// - `withdraw` carrying `Amount`, then `AtCash`
/// - `quit` carrying `Nil`, then `Ended`
///
pub fn session(
  channel: Channel(Session, msg),
) -> Channel(core.Choose(core.Send(Amount, AtBalance), SessionOtherwise), msg) {
  core.unchecked_position(channel)
}

/// The arms of `Session` that are still open once the earlier ones have been
/// ruled out.
///
/// - `withdraw` carrying `Amount`, then `AtCash`
/// - `quit` carrying `Nil`, then `Ended`
///
pub fn session_otherwise(
  channel: Channel(SessionOtherwise, msg),
) -> Channel(core.Choose(core.Send(Amount, AtCash), core.Send(Nil, Ended)), msg) {
  core.unchecked_position(channel)
}

/// Accept `balance` from `Teller`, carrying `Amount`, then continue at
/// `Session`.
///
pub fn at_balance(
  channel: Channel(AtBalance, msg),
) -> Channel(core.Recv(Amount, Session), msg) {
  core.unchecked_position(channel)
}

/// Accept `cash` from `Teller`, carrying `Amount`, then continue at `Session`.
///
pub fn at_cash(
  channel: Channel(AtCash, msg),
) -> Channel(core.Recv(Amount, Session), msg) {
  core.unchecked_position(channel)
}

/// Nothing is owed in either direction. A channel here can be closed with
/// `core.finish`, and nothing else.
///
pub fn ended(channel: Channel(Ended, msg)) -> Channel(core.Done, msg) {
  core.unchecked_position(channel)
}

// CHOICES

/// Take the `deposit` arm of `Session`, which continues at `AtBalance`.
///
pub fn session_deposit(
  channel: Channel(Session, msg),
) -> Channel(core.Send(Amount, AtBalance), msg) {
  channel |> session |> core.choose_left
}

/// Take the `withdraw` arm of `Session`, which continues at `AtCash`.
///
pub fn session_withdraw(
  channel: Channel(Session, msg),
) -> Channel(core.Send(Amount, AtCash), msg) {
  channel
  |> session
  |> core.choose_right
  |> session_otherwise
  |> core.choose_left
}

/// Take the `quit` arm of `Session`, which continues at `Ended`.
///
pub fn session_quit(
  channel: Channel(Session, msg),
) -> Channel(core.Send(Nil, Ended), msg) {
  channel
  |> session
  |> core.choose_right
  |> session_otherwise
  |> core.choose_right
}
