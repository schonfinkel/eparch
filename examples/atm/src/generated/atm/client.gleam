////
//// The `Client` view of the `atm` protocol, written by `eparch/protocol/emit`.
////
//// Edits here are lost the next time it is generated. Change the specification
//// instead.
////
//// Each position below is an uninhabited type. The function named after it
//// unfolds it into the `eparch/session/core` shape the protocol says it has,
//// one step deep, and everything after that is an ordinary `core` or
//// `eparch/protocol_machine` call.
////

import atm/money.{type Amount, type CardId}
import eparch/session/core.{type Channel}
import gleam/erlang/process.{type Pid}

// POSITIONS

/// Send `card` to `Atm`, carrying `CardId`, then continue at `Screening`.
///
pub type AwaitingCard

/// `Atm` picks, so every arm needs a continuation:
///
/// - `ok` carrying `Nil`, then `Serving`
/// - `err` carrying `Nil`, then `Ended`
///
pub type Screening

/// Pick one arm and tell `Atm` which:
///
/// - `deposit` carrying `Amount`, then `Reporting`
/// - `withdraw` carrying `Amount`, then `Assessing`
/// - `quit` carrying `Nil`, then `Ended`
///
pub type Serving

/// The arms of `Serving` that are still open once the earlier ones have been
/// ruled out.
///
/// - `withdraw` carrying `Amount`, then `Assessing`
/// - `quit` carrying `Nil`, then `Ended`
///
pub type ServingOtherwise

/// Accept `balance` from `Atm`, carrying `Amount`, then continue at `Serving`.
///
pub type Reporting

/// `Atm` picks, so every arm needs a continuation:
///
/// - `ok` carrying `Nil`, then `Serving`
/// - `err` carrying `Nil`, then `Serving`
///
pub type Assessing

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
pub fn begin(peer: Pid) -> Channel(AwaitingCard, msg) {
  core.begin(peer, protocol: "atm")
}

// UNFOLDING

/// Send `card` to `Atm`, carrying `CardId`, then continue at `Screening`.
///
pub fn awaiting_card(
  channel: Channel(AwaitingCard, msg),
) -> Channel(core.Send(CardId, Screening), msg) {
  core.unchecked_position(channel)
}

/// `Atm` picks, so every arm needs a continuation:
///
/// - `ok` carrying `Nil`, then `Serving`
/// - `err` carrying `Nil`, then `Ended`
///
pub fn screening(
  channel: Channel(Screening, msg),
) -> Channel(core.Offer(core.Recv(Nil, Serving), core.Recv(Nil, Ended)), msg) {
  core.unchecked_position(channel)
}

/// Pick one arm and tell `Atm` which:
///
/// - `deposit` carrying `Amount`, then `Reporting`
/// - `withdraw` carrying `Amount`, then `Assessing`
/// - `quit` carrying `Nil`, then `Ended`
///
pub fn serving(
  channel: Channel(Serving, msg),
) -> Channel(core.Choose(core.Send(Amount, Reporting), ServingOtherwise), msg) {
  core.unchecked_position(channel)
}

/// The arms of `Serving` that are still open once the earlier ones have been
/// ruled out.
///
/// - `withdraw` carrying `Amount`, then `Assessing`
/// - `quit` carrying `Nil`, then `Ended`
///
pub fn serving_otherwise(
  channel: Channel(ServingOtherwise, msg),
) -> Channel(
  core.Choose(core.Send(Amount, Assessing), core.Send(Nil, Ended)),
  msg,
) {
  core.unchecked_position(channel)
}

/// Accept `balance` from `Atm`, carrying `Amount`, then continue at `Serving`.
///
pub fn reporting(
  channel: Channel(Reporting, msg),
) -> Channel(core.Recv(Amount, Serving), msg) {
  core.unchecked_position(channel)
}

/// `Atm` picks, so every arm needs a continuation:
///
/// - `ok` carrying `Nil`, then `Serving`
/// - `err` carrying `Nil`, then `Serving`
///
pub fn assessing(
  channel: Channel(Assessing, msg),
) -> Channel(core.Offer(core.Recv(Nil, Serving), core.Recv(Nil, Serving)), msg) {
  core.unchecked_position(channel)
}

/// Nothing is owed in either direction. A channel here can be closed with
/// `core.finish`, and nothing else.
///
pub fn ended(channel: Channel(Ended, msg)) -> Channel(core.Done, msg) {
  core.unchecked_position(channel)
}

// CHOICES

/// Follow the `ok` arm of `Screening`, which continues at `Serving`.
///
pub fn screening_ok(
  channel: Channel(Screening, msg),
) -> Channel(core.Recv(Nil, Serving), msg) {
  channel |> screening |> core.offered_left
}

/// Follow the `err` arm of `Screening`, which continues at `Ended`.
///
pub fn screening_err(
  channel: Channel(Screening, msg),
) -> Channel(core.Recv(Nil, Ended), msg) {
  channel |> screening |> core.offered_right
}

/// Take the `deposit` arm of `Serving`, which continues at `Reporting`.
///
pub fn serving_deposit(
  channel: Channel(Serving, msg),
) -> Channel(core.Send(Amount, Reporting), msg) {
  channel |> serving |> core.choose_left
}

/// Take the `withdraw` arm of `Serving`, which continues at `Assessing`.
///
pub fn serving_withdraw(
  channel: Channel(Serving, msg),
) -> Channel(core.Send(Amount, Assessing), msg) {
  channel
  |> serving
  |> core.choose_right
  |> serving_otherwise
  |> core.choose_left
}

/// Take the `quit` arm of `Serving`, which continues at `Ended`.
///
pub fn serving_quit(
  channel: Channel(Serving, msg),
) -> Channel(core.Send(Nil, Ended), msg) {
  channel
  |> serving
  |> core.choose_right
  |> serving_otherwise
  |> core.choose_right
}

/// Follow the `ok` arm of `Assessing`, which continues at `Serving`.
///
pub fn assessing_ok(
  channel: Channel(Assessing, msg),
) -> Channel(core.Recv(Nil, Serving), msg) {
  channel |> assessing |> core.offered_left
}

/// Follow the `err` arm of `Assessing`, which continues at `Serving`.
///
pub fn assessing_err(
  channel: Channel(Assessing, msg),
) -> Channel(core.Recv(Nil, Serving), msg) {
  channel |> assessing |> core.offered_right
}
