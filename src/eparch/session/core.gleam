//// Compile-time protocol positions for two-party conversations.
////
//// A `Channel(protocol, msg)` is a handle on a conversation with one peer.
//// The `protocol` parameter is a *phantom*: it records the whole remaining
//// conversation as a type, has no runtime representation, and exists only to
//// be compared by the compiler. The compiled record holds a pid, an optional
//// monitor and some metadata, and nothing else.
////
//// The type is opaque, so `protocol` can only change through the steps below,
//// and each of those strips exactly one marker off the front of the protocol
//// and leaves the continuation behind. That is the property the guarantee
//// rests on: a step cannot invent a position, it can only go where the
//// protocol type already says.
////
//// ## Describing a protocol
////
//// A protocol is built from five uninhabited markers, each carrying its own
//// continuation:
////
//// | Marker | Meaning |
//// |---|---|
//// | `Send(message, then)` | transmit a `message`, then continue as `then` |
//// | `Recv(message, then)` | accept a `message`, then continue as `then` |
//// | `Choose(left, right)` | *we* pick a branch, then continue as it |
//// | `Offer(left, right)` | *they* pick a branch, then continue as it |
//// | `Done` | the conversation is over |
////
//// ```gleam
//// pub type Deposit =
////   core.Recv(Int, core.Send(Int, core.Done))
////
//// pub type Teller =
////   core.Recv(String, core.Choose(core.Offer(Deposit, Withdraw), core.Done))
//// ```
////
//// A channel at `Deposit` can only `receive` an `Int`, and only then `send`
//// an `Int`, and only then `finish`. Anything else is a type error at the
//// call site.
////
//// ## This module does not own the wire
////
//// `send` hands the message back rather than transmitting it, and `receive`
//// takes a message that has already arrived. Encoding and transport are the
//// caller's, exactly as they are for `eparch/state_machine`.
////
//// That is a deliberate limit, not an omission. Doing the I/O here would mean
//// a blocking receive, and the only place these steps get called from is a
//// `gen_statem` callback, where blocking stalls the process: timeouts do not
//// fire, `sys:get_status/1` hangs, and supervision shutdown goes unanswered.
//// Receiving has to be driven by events instead, which is what
//// `eparch/protocol_machine` does.
////
//// ## Limits
////
//// There is no recursion marker. Expressing a protocol that repeats needs the
//// type checker to substitute a protocol for a variable, and Gleam cannot do
//// that: a type alias defined in terms of itself is rejected outright. A
//// repeating protocol has to be flattened into a state graph with an edge back
//// to an earlier marker, which is `eparch/protocol/emit`'s job rather than
//// this module's. `unchecked_position` at the bottom of this file is what that
//// generated code needs and what it costs.
////
//// Gleam also has no linear types, so nothing stops you keeping an old channel
//// value and stepping it twice. What the types rule out is reaching a position
//// you have no proof of; reusing a proof you already hold is ordinary
//// aliasing. The way to get the missing discipline is to keep the channel
//// somewhere that is *replaced* rather than copied, which is what a
//// `gen_statem`'s data is. See `eparch/protocol_machine`.
////

import gleam/erlang/process.{type Monitor, type Pid}
import gleam/erlang/reference.{type Reference}
import gleam/option.{type Option, None, Some}

// Protocol position markers
/// Transmit a `message`, then continue as `then`.
///
/// ## Example
///
/// ```gleam
/// /// Report the new balance, then hang up.
/// pub type Receipt =
///   core.Send(Int, core.Done)
/// ```
///
pub type Send(message, then)

/// Accept a `message`, then continue as `then`.
///
/// ## Example
///
/// ```gleam
/// /// Take an amount, then report the new balance.
/// pub type Deposit =
///   core.Recv(Int, core.Send(Int, core.Done))
/// ```
///
pub type Recv(message, then)

/// *This* participant picks a branch, and the other must follow.
///
/// ## Example
///
/// ```gleam
/// /// The teller decides whether the card is good for anything.
/// pub type Screening =
///   core.Choose(core.Offer(Deposit, Withdraw), core.Done)
/// ```
///
pub type Choose(left, right)

/// The *other* participant picks a branch, and this one must follow.
///
/// The dual of `Choose`: for every branch they may take, this side has to have
/// a continuation ready.
///
/// ## Example
///
/// ```gleam
/// /// Whatever the customer asks for, the teller can handle.
/// pub type Window =
///   core.Offer(Deposit, Withdraw)
/// ```
///
pub type Offer(left, right)

/// Nothing further is owed in either direction.
///
pub type Done

// The channel
/// A handle on a conversation with one peer, at a known protocol position.
///
/// `protocol` is a phantom parameter carrying the whole remaining
/// conversation; `msg` is the wire message type the peer speaks, which pins a
/// channel to one machine's message type so channels for unrelated protocols
/// cannot be crossed.
///
pub opaque type Channel(protocol, msg) {
  Channel(peer: Pid, watching: Option(Monitor), metadata: Metadata)
}

/// Identifying detail about a channel, readable at any position.
///
/// There is no creation timestamp: `gleam_erlang` exposes no clock, and adding
/// one would mean FFI this layer deliberately does without. Tracing supplies
/// its own timestamps.
///
pub type Metadata {
  Metadata(id: Reference, protocol_name: String, peer: Pid)
}

/// Open a channel to `peer` at a starting position.
///
/// Like the steps below, the position is whatever the annotation says, so call
/// this from an annotated constructor function rather than inline. That one
/// annotation is where a protocol enters the type system, so keep it in the
/// module that declares the protocol where it can be reviewed.
///
/// No monitor is installed. Call `watch` from the process that will own the
/// channel if peer death needs to be observed.
///
/// ## Example
///
/// ```gleam
/// pub fn open(teller: Pid) -> core.Channel(Customer, Request) {
///   core.begin(teller, protocol: "atm")
/// }
/// ```
///
pub fn begin(
  peer: Pid,
  protocol protocol_name: String,
) -> Channel(protocol, msg) {
  Channel(
    peer:,
    watching: None,
    metadata: Metadata(id: reference.new(), protocol_name:, peer:),
  )
}

/// Read a channel's metadata. Valid at any position.
///
pub fn metadata(channel: Channel(protocol, msg)) -> Metadata {
  channel.metadata
}

/// The process on the other end. Valid at any position.
///
pub fn peer(channel: Channel(protocol, msg)) -> Pid {
  channel.peer
}

/// Monitor the peer, so its death arrives as an ordinary `Down` message.
///
/// The monitor belongs to the process that calls this, so call it from the
/// process that will own the channel, not from whoever built it. Calling it
/// twice replaces the first monitor rather than stacking a second.
///
/// Peer death is not an exception here and does not disturb the channel: it
/// arrives as a message like any other, and what to do about it is the
/// owner's decision.
///
/// ## Example
///
/// ```gleam
/// let channel = core.watch(core.begin(teller, protocol: "atm"))
///
/// let selector =
///   process.new_selector()
///   |> process.select_monitors(PeerDied)
/// ```
///
pub fn watch(channel: Channel(protocol, msg)) -> Channel(protocol, msg) {
  let channel = unwatch(channel)
  Channel(..channel, watching: Some(process.monitor(channel.peer)))
}

/// Stop monitoring the peer. Does nothing if the channel is not watched.
///
pub fn unwatch(channel: Channel(protocol, msg)) -> Channel(protocol, msg) {
  case channel.watching {
    Some(monitor) -> {
      process.demonitor_process(monitor:)
      Channel(..channel, watching: None)
    }
    None -> channel
  }
}

/// The monitor installed by `watch`, if there is one.
///
/// Useful for `process.select_specific_monitor`, which needs the monitor
/// itself rather than a blanket selector.
///
pub fn watching(channel: Channel(protocol, msg)) -> Option(Monitor) {
  channel.watching
}

// Position-directed steps
//
// Each strips one marker off the front of the protocol and leaves the
// continuation behind, so unlike a general "move to any position" primitive
// there is nowhere for them to go except where the protocol already says.

/// Transmit the message the protocol calls for, and advance past it.
///
/// Only compiles when the position is `Send(message, then)` and `message` has
/// the type the protocol declared. The message is handed back alongside the
/// advanced channel so the value that was type-checked is the same one that
/// reaches the wire.
///
/// ## Example
///
/// ```gleam
/// // teller: Channel(Send(Int, Done), Wire)
/// let #(balance, teller) = core.send(teller, till.balance)
/// process.send(customer, Balance(balance))
/// ```
///
pub fn send(
  channel: Channel(Send(message, then), msg),
  message: message,
) -> #(message, Channel(then, msg)) {
  #(message, advance(channel))
}

/// Accept the message the protocol calls for, and advance past it.
///
/// The message has already arrived and been narrowed by whatever matched it at
/// the process boundary. Passing it here is what checks that what arrived is
/// what the protocol said would arrive.
///
/// ## Example
///
/// ```gleam
/// // teller: Channel(Recv(String, rest), Wire)
/// let teller = core.receive(teller, card_id)
/// ```
///
pub fn receive(
  channel: Channel(Recv(message, then), msg),
  message: message,
) -> Channel(then, msg) {
  let _ = message
  advance(channel)
}

/// Take the left branch of a choice that is this participant's to make.
///
/// The other participant is at the matching `Offer` and has a continuation
/// ready for either branch, so this cannot strand them.
///
/// ## Example
///
/// ```gleam
/// // teller: Channel(Choose(Window, Done), Wire)
/// // The card is good, so open the window rather than hanging up.
/// let teller = core.choose_left(teller)
/// ```
///
pub fn choose_left(
  channel: Channel(Choose(left, right), msg),
) -> Channel(left, msg) {
  advance(channel)
}

/// Take the right branch of a choice that is this participant's to make.
///
/// ## Example
///
/// ```gleam
/// // The card was refused, so decline and hang up.
/// let teller = core.choose_right(teller)
/// ```
///
pub fn choose_right(
  channel: Channel(Choose(left, right), msg),
) -> Channel(right, msg) {
  advance(channel)
}

/// Follow the left branch, which the *other* participant selected.
///
/// Which branch they took is a runtime fact, learned by matching on the
/// message that arrived. This turns that fact back into a static position, and
/// the `case` that narrows the message is where Gleam's ordinary
/// exhaustiveness checking makes sure every branch has a continuation.
///
/// ## Example
///
/// ```gleam
/// // teller: Channel(Offer(Deposit, Withdraw), Wire)
/// case request {
///   Deposit(amount) -> handle_deposit(core.offered_left(teller), amount)
///   Withdraw(amount) -> handle_withdraw(core.offered_right(teller), amount)
/// }
/// ```
///
pub fn offered_left(
  channel: Channel(Offer(left, right), msg),
) -> Channel(left, msg) {
  advance(channel)
}

/// Follow the right branch, which the *other* participant selected.
///
/// ## Example
///
/// ```gleam
/// let teller = core.offered_right(teller)
/// ```
///
pub fn offered_right(
  channel: Channel(Offer(left, right), msg),
) -> Channel(right, msg) {
  advance(channel)
}

/// End a conversation that has nothing left to exchange.
///
/// Only compiles at `Done`, so a participant that still owes a message cannot
/// hang up on the other one. Drops the monitor if there is one, so call it
/// from the process that called `watch`.
///
/// ## Example
///
/// ```gleam
/// // teller: Channel(Done, Wire)
/// let details = core.finish(teller)
/// ```
///
pub fn finish(channel: Channel(Done, msg)) -> Metadata {
  unwatch(channel).metadata
}

/// Abandon a conversation from any position, owing whatever is still owed.
///
/// The counterpart to `finish`, for giving up rather than completing: a peer
/// that died, a caller that walked away, a supervisor shutting the machine
/// down. Because it is valid anywhere it proves nothing about the protocol,
/// which is exactly why it is named differently from `finish` and why reaching
/// for it should be a considered act.
///
/// Drops the monitor if there is one.
///
pub fn close(channel: Channel(protocol, msg)) -> Metadata {
  unwatch(channel).metadata
}

/// Move a channel to a position the compiler has no reason to believe it is
/// at.
///
/// This is the one hole in everything above, and it exists for one caller: a
/// module written by `eparch/protocol/emit`. A protocol that repeats cannot be
/// spelled as a type, because a Gleam alias defined in terms of itself is
/// rejected outright, so it has to be flattened into named positions with
/// edges between them. Those names are uninhabited types like the markers
/// above, and nothing in the language relates a name to the shape it stands
/// for. This is what relates them, and it is unchecked because there is
/// nothing here to check it against.
///
/// Generated code asserts the same thing a hand-written call would, and the
/// types cannot tell the two apart. The difference is that a generator read
/// the shape off a specification `eparch/protocol/graph` had already checked.
/// Gleam cannot scope a function to part of a package, so the only thing
/// keeping that difference real is that this is left alone.
///
/// ## Example
///
/// ```gleam
/// /// `AtWaiting` is: accept a card number, then `AtServing`.
/// pub fn at_waiting(
///   channel: Channel(AtWaiting, msg),
/// ) -> Channel(core.Recv(String, AtServing), msg) {
///   core.unchecked_position(channel)
/// }
/// ```
///
pub fn unchecked_position(channel: Channel(from, msg)) -> Channel(to, msg) {
  let Channel(peer:, watching:, metadata:) = channel
  Channel(peer:, watching:, metadata:)
}

/// The one place `protocol` changes. Every step above goes through it, so each
/// of them names in its own signature the marker it strips.
fn advance(channel: Channel(from, msg)) -> Channel(to, msg) {
  unchecked_position(channel)
}
