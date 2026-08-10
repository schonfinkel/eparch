//// Drives a session-typed protocol (see `eparch/session/core`) from a
//// `gen_statem`, by lowering onto `eparch/state_machine`.
////
//// ## The problem this solves
////
//// A `gen_statem` receives messages that carry no type information, and its
//// data has one type for the whole life of the process. A protocol position
//// is the opposite: it changes at every step, and each step's channel has a
//// different type. Those two facts cannot be reconciled directly, because
//// Gleam has no existential types, so there is no way to write "a channel at
//// whatever position we happen to be at" as the machine's data.
////
//// The way through is a closure. A `ProtocolState` binds a handler to a
//// channel *at one statically known position*, and building one erases that
//// position by capturing the channel inside a function. What comes back out
//// is protocol-free and can sit in the machine's data. Every handler is
//// written against a concrete position and checked against it; only the
//// machine's storage is untyped, and nothing user-written ever sees it.
////
//// ## Writing a protocol machine
////
//// One function per position, each returning the state for that position:
////
//// ```gleam
//// fn awaiting_name(channel: Channel(Greeter, Wire)) -> Position(Greeter) {
////   protocol_machine.state(
////     tag: AwaitingName,
////     at: channel,
////     data: Nil,
////     handler: fn(event, channel, data) {
////       case event {
////         state_machine.Cast(Name(name)) ->
////           // `accept` only compiles because the position really is a `Recv`,
////           // and only for the payload type the protocol declared.
////           protocol_machine.accept(at: channel, message: name, actions: [],
////             then: fn(next) { greeting(next, name) })
////
////         // Anything the protocol is not ready for waits its turn.
////         _ -> protocol_machine.postpone()
////       }
////     },
////   )
//// }
//// ```
////
//// The continuation is where the next position comes from, and its argument
//// type is derived from the protocol rather than written down, so a handler
//// that returns the wrong next position does not compile.
////
//// ## Tags
////
//// The `gen_statem` state is a small comparable `tag` that each position
//// declares, not the position itself. This is not cosmetic: `gen_statem`
//// compares state values to decide whether a transition happened, and that
//// decision drives `state_enter` re-entry and state-timeout cancellation. A
//// state that carried the payload would make every data change read as a
//// transition, firing spurious `Enter` events and silently cancelling timers.
////
//// The tag is taken from whichever position the machine moves to, so it
//// cannot drift. Give distinct positions distinct tags; two positions sharing
//// a tag make a real transition invisible to `gen_statem`.
////
//// ## Dependencies
////
//// There is no dependency-injection facility, by design. A handler is an
//// ordinary closure, so capture whatever the protocol needs from the
//// enclosing scope:
////
//// ```gleam
//// fn build(deps: Deps) {
////   fn(event, channel, data) { handle(event, channel, data, deps) }
//// }
//// ```
////
//// Keeping dependencies in the closure rather than in the channel is what
//// lets a channel stay cheap and sendable.
////
//// ## This module does not own the wire
////
//// Like `eparch/session/core`, it performs no I/O. `transmit` checks a
//// message against the protocol and hands it to the continuation; putting it
//// on the wire is the handler's job, with an ordinary `process.send`. What
//// this module owns is the *position*, and the guarantee that the position
//// only ever moves where the protocol allows.
////

import eparch/session/core.{type Channel}
import eparch/session/patterns
import eparch/state_machine.{type Action, type Event}
import gleam/erlang/process.{type ExitReason}
import gleam/option.{type Option, None, Some}

// ===============================================================
// Core types
// ===============================================================

/// A protocol position with a handler bound to it.
///
/// `protocol` is a phantom parameter naming the position this state sits at.
/// It constrains which transitions the handler may return, and is erased the
/// moment the state is built.
///
/// The five parameters are a lot to read. Alias them once per protocol:
///
/// ```gleam
/// type Position(protocol) =
///   protocol_machine.ProtocolState(protocol, AuthTag, AuthData, Wire, Reply)
/// ```
///
pub opaque type ProtocolState(protocol, tag, internal, msg, reply) {
  ProtocolState(erased: Running(tag, internal, msg, reply))
}

/// A protocol position with its position erased, which is what the machine
/// actually stores. Opaque, and never built by hand: it comes out of `state`.
///
pub opaque type Running(tag, internal, msg, reply) {
  Running(
    tag: tag,
    data: internal,
    run: fn(Event(tag, msg, reply), internal) ->
      Progress(tag, internal, msg, reply),
  )
}

/// What a handler decided to do. Opaque, and constrained by `protocol`: the
/// constructors below each demand a channel at the position they apply to, so
/// a transmit at a receive position is a type error rather than a comment.
///
pub opaque type ProtocolTransition(protocol, tag, internal, msg, reply) {
  ProtocolTransition(progress: Progress(tag, internal, msg, reply))
}

/// The protocol-free residue of a transition, after the continuation has been
/// applied and the next position erased.
type Progress(tag, internal, msg, reply) {
  /// Move to a new position.
  Advanced(
    next: Running(tag, internal, msg, reply),
    actions: List(Action(msg, reply)),
  )
  /// Stay put, with new internal data.
  Held(data: internal, actions: List(Action(msg, reply)))
  /// The event arrived out of protocol order. Wait for a position that wants it.
  Waiting
  /// The event is a protocol violation. Stay put and report it.
  Refused(reason: String, actions: List(Action(msg, reply)))
  /// Terminate.
  Stopped(reason: ExitReason, actions: List(Action(msg, reply)))
}

/// A rejected event, as passed to the `on_violation` hook.
///
pub type Violation(tag, msg, reply) {
  Violation(
    /// The reason given to `reject`.
    reason: String,
    /// The position the machine was at when the event arrived.
    tag: tag,
    /// The offending event.
    event: Event(tag, msg, reply),
  )
}

// ===============================================================
// Building a position
// ===============================================================

/// Bind a handler to a channel at a known position.
///
/// This is where a position is erased: `channel` is captured inside the
/// returned value at its static type, and everything outside sees a value with
/// no protocol in it. That is what lets positions of different types live in
/// one machine.
///
/// `tag` is the `gen_statem` state for as long as the machine sits here, so
/// keep it small and comparable, and distinct from other positions' tags.
///
/// ## Example
///
/// ```gleam
/// fn awaiting_name(channel: Channel(Greeter, Wire)) -> Position(Greeter) {
///   protocol_machine.state(
///     tag: AwaitingName,
///     at: channel,
///     data: Nil,
///     handler: fn(event, channel, data) {
///       case event {
///         state_machine.Cast(Name(name)) ->
///           protocol_machine.accept(at: channel, message: name, actions: [],
///             then: fn(next) { greeting(next, name) })
///         _ -> protocol_machine.postpone()
///       }
///     },
///   )
/// }
/// ```
///
pub fn state(
  tag tag: tag,
  at channel: Channel(protocol, msg),
  data data: internal,
  handler handler: fn(Event(tag, msg, reply), Channel(protocol, msg), internal) ->
    ProtocolTransition(protocol, tag, internal, msg, reply),
) -> ProtocolState(protocol, tag, internal, msg, reply) {
  ProtocolState(
    erased: Running(tag:, data:, run: fn(event, current) {
      let ProtocolTransition(progress) = handler(event, channel, current)
      progress
    }),
  )
}

/// Take a step from a generated position, along a route that reaches it.
///
/// `eparch/protocol/emit` writes protocols that repeat as flat named
/// positions, because a type that loops cannot be written any other way. A
/// name like that is not a `Send` or a `Recv`, so the transitions below will
/// not take it directly: the generated module has a function turning the name
/// into the shape it stands for, and this is what threads a transition through
/// one of those.
///
/// Nothing new is asserted here. `route` is the generated function, and
/// supplying it is what ties the two positions together; a `ProtocolTransition`
/// carries no protocol inside it, so relabelling one is only ever as sound as
/// the route handed in.
///
/// The routes worth knowing about are the ones a generated module writes for a
/// choice of three or more arms. `core` branches two ways at a time, so a
/// wider choice nests, and a route walks the whole nest in one step. That is
/// what keeps one arm to one `case` clause here instead of one arm per level.
///
/// ## Example
///
/// ```gleam
/// fn at_session(channel: Channel(teller.Session, Wire)) -> Position(teller.Session) {
///   protocol_machine.state(
///     tag: Serving,
///     at: channel,
///     data: Nil,
///     handler: fn(event, channel, _data) {
///       case event {
///         state_machine.Cast(Deposit(amount)) ->
///           protocol_machine.along(
///             at: channel,
///             route: teller.session_deposit,
///             step: protocol_machine.accept(
///               at: _,
///               message: amount,
///               actions: [],
///               then: fn(next) { at_balance(next) },
///             ),
///           )
///
///         _ -> protocol_machine.postpone()
///       }
///     },
///   )
/// }
/// ```
///
pub fn along(
  at channel: Channel(position, msg),
  route route: fn(Channel(position, msg)) -> Channel(shape, msg),
  step step: fn(Channel(shape, msg)) ->
    ProtocolTransition(shape, tag, internal, msg, reply),
) -> ProtocolTransition(position, tag, internal, msg, reply) {
  let ProtocolTransition(progress) = step(route(channel))
  ProtocolTransition(progress:)
}

// ===============================================================
// Position-constrained transitions
// ===============================================================

//
// Each takes the channel it applies to, so the protocol parameter is pinned by
// the argument rather than left free. That is the whole difference between a
// phantom that constrains something and a phantom that decorates it.

/// Transmit the message the protocol calls for, then continue.
///
/// Only compiles at `Send(message, then)`, and only for the payload type the
/// protocol declared. The checked message is handed to the continuation so it
/// can go on the wire there: this module does no I/O.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.transmit(
///   at: channel,
///   message: "hello " <> name,
///   actions: [],
///   then: fn(greeting, next) {
///     process.send(peer, Greeting(greeting))
///     awaiting_farewell(next)
///   },
/// )
/// ```
///
pub fn transmit(
  at channel: Channel(core.Send(message, then), msg),
  message message: message,
  actions actions: List(Action(msg, reply)),
  then next: fn(message, Channel(then, msg)) ->
    ProtocolState(then, tag, internal, msg, reply),
) -> ProtocolTransition(core.Send(message, then), tag, internal, msg, reply) {
  let #(checked, advanced) = core.send(channel, message)
  continue(next(checked, advanced), actions)
}

/// Accept the message the protocol calls for, then continue.
///
/// Only compiles at `Recv(message, then)`. The message has already arrived and
/// been narrowed by the `case` in the handler; passing it here is what checks
/// that what arrived is what the protocol said would arrive.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.accept(at: channel, message: name, actions: [], then: fn(next) {
///   greeting(next, name)
/// })
/// ```
///
pub fn accept(
  at channel: Channel(core.Recv(message, then), msg),
  message message: message,
  actions actions: List(Action(msg, reply)),
  then next: fn(Channel(then, msg)) ->
    ProtocolState(then, tag, internal, msg, reply),
) -> ProtocolTransition(core.Recv(message, then), tag, internal, msg, reply) {
  continue(next(core.receive(channel, message)), actions)
}

/// Take the left branch of a choice that is this machine's to make.
///
/// Only compiles at `Choose(left, right)`. Tell the peer which branch you took,
/// or their matching `Offer` cannot follow.
///
pub fn pick_left(
  at channel: Channel(core.Choose(left, right), msg),
  actions actions: List(Action(msg, reply)),
  then next: fn(Channel(left, msg)) ->
    ProtocolState(left, tag, internal, msg, reply),
) -> ProtocolTransition(core.Choose(left, right), tag, internal, msg, reply) {
  continue(next(core.choose_left(channel)), actions)
}

/// Take the right branch of a choice that is this machine's to make.
///
pub fn pick_right(
  at channel: Channel(core.Choose(left, right), msg),
  actions actions: List(Action(msg, reply)),
  then next: fn(Channel(right, msg)) ->
    ProtocolState(right, tag, internal, msg, reply),
) -> ProtocolTransition(core.Choose(left, right), tag, internal, msg, reply) {
  continue(next(core.choose_right(channel)), actions)
}

/// Follow the left branch, which the *peer* selected.
///
/// Only compiles at `Offer(left, right)`. Which branch they took is a runtime
/// fact learned by matching on the message that arrived; this turns it back
/// into a static position. The `case` doing the matching is where Gleam's
/// ordinary exhaustiveness checking makes sure every branch has a continuation.
///
pub fn follow_left(
  at channel: Channel(core.Offer(left, right), msg),
  actions actions: List(Action(msg, reply)),
  then next: fn(Channel(left, msg)) ->
    ProtocolState(left, tag, internal, msg, reply),
) -> ProtocolTransition(core.Offer(left, right), tag, internal, msg, reply) {
  continue(next(core.offered_left(channel)), actions)
}

/// Follow the right branch, which the *peer* selected.
///
pub fn follow_right(
  at channel: Channel(core.Offer(left, right), msg),
  actions actions: List(Action(msg, reply)),
  then next: fn(Channel(right, msg)) ->
    ProtocolState(right, tag, internal, msg, reply),
) -> ProtocolTransition(core.Offer(left, right), tag, internal, msg, reply) {
  continue(next(core.offered_right(channel)), actions)
}

/// Which way a branch went.
///
/// Produced by matching on whatever message announced it, and consumed by
/// `follow` or `pick`.
///
pub type Branch {
  Left
  Right
}

/// Follow the branch the *peer* selected, with a continuation ready for either.
///
/// The difference from `follow_left` and `follow_right` is that both
/// continuations are arguments, so a branch cannot be left unhandled: the
/// compiler counts arguments. This is the guarantee ST-DESIGN.md wanted from a
/// `List(BranchHandler)` and could not get, because a list has no arity the
/// compiler knows about.
///
/// ## Example
///
/// ```gleam
/// let taken = case announcement {
///   CarryOn -> protocol_machine.Left
///   HangUp -> protocol_machine.Right
/// }
///
/// protocol_machine.follow(
///   at: channel,
///   taking: taken,
///   actions: [],
///   left: fn(next) { chatting(next) },
///   right: fn(next) { saying_goodbye(next) },
/// )
/// ```
///
pub fn follow(
  at channel: Channel(core.Offer(left, right), msg),
  taking branch: Branch,
  actions actions: List(Action(msg, reply)),
  left on_left: fn(Channel(left, msg)) ->
    ProtocolState(left, tag, internal, msg, reply),
  right on_right: fn(Channel(right, msg)) ->
    ProtocolState(right, tag, internal, msg, reply),
) -> ProtocolTransition(core.Offer(left, right), tag, internal, msg, reply) {
  case branch {
    Left -> continue(on_left(core.offered_left(channel)), actions)
    Right -> continue(on_right(core.offered_right(channel)), actions)
  }
}

/// Take a branch that is this machine's to choose, with a continuation ready
/// for either.
///
/// The counterpart to `follow`, for `Choose` rather than `Offer`. Tell the peer
/// which way you went, or their matching `Offer` cannot follow.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.pick(
///   at: channel,
///   taking: case data.attempts > 3 {
///     True -> protocol_machine.Right
///     False -> protocol_machine.Left
///   },
///   actions: [],
///   left: fn(next) { retrying(next) },
///   right: fn(next) { giving_up(next) },
/// )
/// ```
///
pub fn pick(
  at channel: Channel(core.Choose(left, right), msg),
  taking branch: Branch,
  actions actions: List(Action(msg, reply)),
  left on_left: fn(Channel(left, msg)) ->
    ProtocolState(left, tag, internal, msg, reply),
  right on_right: fn(Channel(right, msg)) ->
    ProtocolState(right, tag, internal, msg, reply),
) -> ProtocolTransition(core.Choose(left, right), tag, internal, msg, reply) {
  case branch {
    Left -> continue(on_left(core.choose_left(channel)), actions)
    Right -> continue(on_right(core.choose_right(channel)), actions)
  }
}

/// Take a question and answer it in one step.
///
/// Only compiles at `patterns.Serve(question, answer, then)`. Collapsing the
/// receive and the send into one transition buys more than brevity: written
/// longhand the send needs its own position and an `advance_now` to wake it,
/// because a `Send` position has nothing to wait for. Here the whole fragment
/// runs while the triggering event is still in hand.
///
/// The answer goes to the continuation rather than on the wire, since this
/// module does no I/O.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.answer(
///   at: channel,
///   question: account,
///   with: fn(account) { ledger.balance(account) },
///   actions: [],
///   then: fn(balance, next) {
///     process.send(customer, Balance(balance))
///     idle(next)
///   },
/// )
/// ```
///
pub fn answer(
  at channel: Channel(patterns.Serve(question, answer, then), msg),
  question question: question,
  with respond: fn(question) -> answer,
  actions actions: List(Action(msg, reply)),
  then next: fn(answer, Channel(then, msg)) ->
    ProtocolState(then, tag, internal, msg, reply),
) -> ProtocolTransition(
  patterns.Serve(question, answer, then),
  tag,
  internal,
  msg,
  reply,
) {
  let sending = core.receive(channel, question)
  let #(answered, advanced) = core.send(sending, respond(question))
  continue(next(answered, advanced), actions)
}

/// Take a proposal and decide which way the protocol goes, in one step.
///
/// Only compiles at `patterns.Decide(proposal, accepted, rejected)`. Both
/// outcomes need a continuation, so neither can be forgotten, and because they
/// are separate arguments they may lead to genuinely different protocols.
///
/// Tell the peer which way you went, or their matching `Offer` cannot follow.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.decide(
///   at: channel,
///   proposal: offer,
///   choosing: fn(offer) { offer.price <= budget },
///   actions: [],
///   accepted: fn(next) {
///     process.send(seller, Accepted)
///     settling(next)
///   },
///   rejected: fn(next) {
///     process.send(seller, Rejected)
///     walking_away(next)
///   },
/// )
/// ```
///
pub fn decide(
  at channel: Channel(patterns.Decide(proposal, accepted, rejected), msg),
  proposal proposal: proposal,
  choosing choose: fn(proposal) -> Bool,
  actions actions: List(Action(msg, reply)),
  accepted on_accept: fn(Channel(accepted, msg)) ->
    ProtocolState(accepted, tag, internal, msg, reply),
  rejected on_reject: fn(Channel(rejected, msg)) ->
    ProtocolState(rejected, tag, internal, msg, reply),
) -> ProtocolTransition(
  patterns.Decide(proposal, accepted, rejected),
  tag,
  internal,
  msg,
  reply,
) {
  let choosing = core.receive(channel, proposal)
  case choose(proposal) {
    True -> continue(on_accept(core.choose_left(choosing)), actions)
    False -> continue(on_reject(core.choose_right(choosing)), actions)
  }
}

/// Complete the protocol and stop the machine normally.
///
/// Only compiles at `Done`, so a machine that still owes the peer a message
/// cannot hang up on it. Drops the channel's monitor.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.complete(at: channel, actions: [state_machine.reply(from, Ok(Nil))])
/// ```
///
pub fn complete(
  at channel: Channel(core.Done, msg),
  actions actions: List(Action(msg, reply)),
) -> ProtocolTransition(core.Done, tag, internal, msg, reply) {
  let _ = core.finish(channel)
  ProtocolTransition(Stopped(process.Normal, actions))
}

fn continue(
  next: ProtocolState(protocol, tag, internal, msg, reply),
  actions: List(Action(msg, reply)),
) -> ProtocolTransition(any, tag, internal, msg, reply) {
  let ProtocolState(erased) = next
  ProtocolTransition(Advanced(erased, actions))
}

// ===============================================================
// Transitions valid at any position
// ===============================================================

//
// These leave `protocol` free, and that is honest rather than sloppy: none of
// them moves along the protocol, so there is no position to constrain. The
// failure mode called out in ST-PLAN.md is a constructor that *claims* to be
// position-restricted while leaving the parameter free. These do not claim it.

/// Stay at this position, with new internal data.
///
/// For accumulating between protocol steps: counting attempts, appending to a
/// buffer. It moves no protocol, so the next event arrives at the same
/// position with the same handler.
///
pub fn hold(
  data data: internal,
  actions actions: List(Action(msg, reply)),
) -> ProtocolTransition(protocol, tag, internal, msg, reply) {
  ProtocolTransition(Held(data, actions))
}

/// Wait: this event arrived out of protocol order.
///
/// Lowers to `gen_statem`'s `postpone`, so the event is held and redelivered
/// after the next position change, when a handler that wants it may be in
/// place. This is the right answer for a message that is legitimate but early,
/// and the wrong one for a message that is simply invalid: postponing that
/// leaks, because nothing will ever consume it. Use `reject` for those.
///
/// ## Example
///
/// ```gleam
/// case event {
///   state_machine.Cast(Name(name)) -> protocol_machine.accept(...)
///   // Not what this position is waiting for, but may be later.
///   _ -> protocol_machine.postpone()
/// }
/// ```
///
pub fn postpone() -> ProtocolTransition(protocol, tag, internal, msg, reply) {
  ProtocolTransition(Waiting)
}

/// Refuse this event as a protocol violation, and stay where you are.
///
/// The position is untouched, the `on_violation` hook fires, and the actions
/// still run so a pending caller can be told why. This is the graceful
/// degradation path: a peer that speaks out of turn should not take the
/// machine down with it.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.reject("capture requires an authorised payment", [
///   state_machine.reply(from, Error(NotAuthorised)),
/// ])
/// ```
///
pub fn reject(
  reason: String,
  actions: List(Action(msg, reply)),
) -> ProtocolTransition(protocol, tag, internal, msg, reply) {
  ProtocolTransition(Refused(reason, actions))
}

/// Abandon the protocol and stop the machine, owing whatever is still owed.
///
/// The counterpart to `complete`, for giving up rather than finishing: a peer
/// that died, a timeout that expired, a precondition that failed. Drops the
/// channel's monitor. Because it is valid anywhere it proves nothing about the
/// protocol, which is why it is named differently from `complete`.
///
pub fn fail(
  at channel: Channel(protocol, msg),
  reason reason: ExitReason,
  actions actions: List(Action(msg, reply)),
) -> ProtocolTransition(protocol, tag, internal, msg, reply) {
  let _ = core.close(channel)
  ProtocolTransition(Stopped(reason, actions))
}

/// Drive the position the machine is about to reach, without waiting for the
/// peer.
///
/// A machine only acts when an event arrives, but a `Send` position has
/// nothing to wait for: the protocol says it is this side's turn to speak.
/// Include this in a transition's `actions` and the next position is handed a
/// synthetic event immediately, so it can transmit and move on.
///
/// The event arrives as `Cast(content)`, because `gen_statem` internal events
/// surface that way.
///
/// ## Example
///
/// ```gleam
/// // Take the name, then immediately wake the Send position that follows it.
/// protocol_machine.accept(
///   at: channel,
///   message: name,
///   actions: [protocol_machine.advance_now(Proceed)],
///   then: fn(next) { greeting(next, name) },
/// )
/// ```
///
pub fn advance_now(content: msg) -> Action(msg, reply) {
  state_machine.next_event(state_machine.InternalEvent, content)
}

// ===============================================================
// The machine
// ===============================================================

/// A builder for a protocol-driven state machine.
///
/// The protocol parameter is gone: it was erased when the initial position was
/// built, which is what lets one machine hold positions of different types.
///
pub opaque type Builder(tag, internal, msg, reply) {
  Builder(
    initial: Running(tag, internal, msg, reply),
    on_violation: Option(fn(Violation(tag, msg, reply)) -> Nil),
    timeout: Option(#(Int, msg)),
  )
}

/// Create a builder from the position the protocol starts at.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.new(awaiting_name(channel))
/// |> protocol_machine.start_link
/// ```
///
pub fn new(
  initial: ProtocolState(protocol, tag, internal, msg, reply),
) -> Builder(tag, internal, msg, reply) {
  let ProtocolState(erased) = initial
  Builder(initial: erased, on_violation: None, timeout: None)
}

/// Set a hook called whenever a handler returns `reject`.
///
/// Useful for logging or metering protocol violations in one place rather than
/// at every rejection site.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.on_violation(builder, fn(violation) {
///   io.println("protocol violation: " <> violation.reason)
/// })
/// ```
///
pub fn on_violation(
  builder: Builder(tag, internal, msg, reply),
  hook: fn(Violation(tag, msg, reply)) -> Nil,
) -> Builder(tag, internal, msg, reply) {
  Builder(..builder, on_violation: Some(hook))
}

/// Arm a state timeout every time the machine reaches a new position.
///
/// A protocol that stalls halfway through should not sit there forever. The
/// timer is re-armed on each move, so it measures time spent waiting at one
/// position, and it is delivered as an ordinary `Timeout` event that the
/// current handler can answer however it likes (usually with `fail`).
///
/// ## Example
///
/// ```gleam
/// protocol_machine.with_timeout(builder, after: 5000, sending: SessionStalled)
/// ```
///
pub fn with_timeout(
  builder: Builder(tag, internal, msg, reply),
  after milliseconds: Int,
  sending content: msg,
) -> Builder(tag, internal, msg, reply) {
  Builder(..builder, timeout: Some(#(milliseconds, content)))
}

/// Lower this builder to a plain `state_machine.Builder`.
///
/// Everything `eparch/state_machine` offers (naming, hibernation, debug flags,
/// `with_state_enter`, `on_format_status`) is applied at that level rather than
/// duplicated here.
///
/// ## Example
///
/// ```gleam
/// protocol_machine.new(awaiting_name(channel))
/// |> protocol_machine.to_state_machine
/// |> state_machine.named(state_machine.Local(name))
/// |> state_machine.start_link
/// ```
///
pub fn to_state_machine(
  builder: Builder(tag, internal, msg, reply),
) -> state_machine.Builder(tag, Running(tag, internal, msg, reply), msg, reply) {
  let Builder(initial:, on_violation:, timeout:) = builder

  state_machine.new(initial_state: initial.tag, initial_data: initial)
  |> state_machine.on_event(fn(event, current_tag, position) {
    case position.run(event, position.data) {
      Advanced(next, actions) -> {
        let actions = arm(timeout, actions)
        case next.tag == current_tag {
          True -> state_machine.keep_state(next, actions)
          False -> state_machine.next_state(next.tag, next, actions)
        }
      }

      Held(data, actions) ->
        state_machine.keep_state(Running(..position, data:), actions)

      Waiting -> state_machine.keep_state_and_data([state_machine.postpone()])

      Refused(reason, actions) -> {
        notify(on_violation, reason, current_tag, event)
        state_machine.keep_state(position, actions)
      }

      Stopped(reason, actions) ->
        case actions {
          [] -> state_machine.stop(reason)
          [_, ..] -> state_machine.stop_and_reply(reason, actions)
        }
    }
  })
}

fn arm(
  timeout: Option(#(Int, msg)),
  actions: List(Action(msg, reply)),
) -> List(Action(msg, reply)) {
  case timeout {
    Some(#(milliseconds, content)) -> [
      state_machine.state_timeout(state_machine.After(milliseconds), content),
      ..actions
    ]
    None -> actions
  }
}

fn notify(
  hook: Option(fn(Violation(tag, msg, reply)) -> Nil),
  reason: String,
  tag: tag,
  event: Event(tag, msg, reply),
) -> Nil {
  case hook {
    Some(run) -> run(Violation(reason:, tag:, event:))
    None -> Nil
  }
}

/// Start the machine linked to the caller.
///
/// Shorthand for `to_state_machine` followed by `state_machine.start_link`.
///
pub fn start_link(
  builder: Builder(tag, internal, msg, reply),
) -> state_machine.StartResult(msg) {
  builder |> to_state_machine |> state_machine.start_link
}

/// Start the machine without linking it to the caller.
///
pub fn start(
  builder: Builder(tag, internal, msg, reply),
) -> state_machine.StartResult(msg) {
  builder |> to_state_machine |> state_machine.start
}
