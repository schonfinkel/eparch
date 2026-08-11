//// Reusable protocol fragments, and the duality witnesses that go with them.
////
//// A fragment is an ordinary protocol from `eparch/session/core` with one
//// extra type parameter: `then`, standing for whatever follows it. That single
//// convention is what makes protocols composable, and it is worth
//// understanding before reading anything else here.
////
//// ## Composition is type application
////
//// Sequencing two protocols means replacing the first one's `Done` with the
//// second. That is a substitution, and Gleam's type system cannot perform
//// substitutions. But it does not have to: if a fragment leaves a hole where
//// its continuation goes, sequencing is just filling the hole.
////
//// ```gleam
//// /// Ask once, then whatever comes next.
//// pub type Request(question, answer, then) =
////   core.Send(question, core.Recv(answer, then))
////
//// /// Ask twice, then stop. No combinator involved.
//// pub type AskTwice =
////   Request(String, Int, Request(String, Int, core.Done))
//// ```
////
//// The same holds for the proofs. A fragment's witness takes the
//// continuation's witness and returns the whole one, so composing two
//// fragments is composing two functions:
////
//// ```gleam
//// pub fn ask_twice() -> Dual(AskTwice, ServeTwice) {
////   patterns.request(patterns.request(duality.done()))
//// }
//// ```
////
//// This is why there is no `combinators` module and no `seq` operator. Both
//// would be a wrapper around something the language already does: type
//// application in one case, function application in the other. Writing your
//// own fragments needs nothing from this module beyond the convention.
////
//// There is a second reason. A general `seq` would have to apply a fragment
//// whose type variables are instantiated differently at each use, which needs
//// rank-2 polymorphism. Gleam does not have it, so `fn(f) { fn(x) { f(f(x)) } }`
//// does not type check for any real fragment. Nesting at the call site is
//// unaffected and has no depth limit; only abstracting over the nesting is out
//// of reach.
////
//// ## What cannot be composed this way
////
//// **Iteration.** A protocol that repeats needs its own name to appear inside
//// its own definition, and Gleam rejects that outright as a type cycle. No
//// arrangement of parameters gets around it, because the hole would have to be
//// filled with the very thing being defined. Repetition has to be flattened
//// into a state graph with an edge back to an earlier marker, which is a
//// generator's job rather than a type's.
////
//// **Interleaving.** Filling a hole can only put one protocol *after* another.
//// It cannot weave two protocols together, which is what you need when a
//// service and the authentication it depends on have to advance in step: the
//// login must precede the menu, and each payment needs its own second factor.
//// No arrangement of `then` parameters expresses that, because the two
//// protocols constrain each other in both directions.
////
//// This is a real gap rather than an impossibility. Bocchi, Orchard and
//// Voinea's *A Theory of Composing Protocols* (2023) resolves it by annotating
//// protocols with `assert` / `require` / `consume` contact points and computing
//// the valid interleavings, yielding a single protocol to program against.
//// Because the result is one ordinary protocol, it needs nothing from the type
//// system: it belongs in a specification-time generator, alongside the
//// flattening that iteration also needs. See `docs/Session_Types.md`.
////

import eparch/session/core
import eparch/session/duality.{type Dual}

// Request and response

/// Ask a question, take the answer, then continue.
///
/// The workhorse fragment. Its dual is `Serve`.
///
/// ## Example
///
/// ```gleam
/// /// Look up a balance, then hang up.
/// pub type Lookup =
///   patterns.Request(AccountId, Money, core.Done)
/// ```
///
pub type Request(question, answer, then) =
  core.Send(question, core.Recv(answer, then))

/// Take a question, answer it, then continue. The dual of `Request`.
///
/// ## Example
///
/// ```gleam
/// pub type Teller =
///   patterns.Serve(AccountId, Money, core.Done)
/// ```
///
pub type Serve(question, answer, then) =
  core.Recv(question, core.Send(answer, then))

/// Witness that a `Request` faces a `Serve`.
///
/// Takes the proof for whatever follows, so fragments nest.
///
/// ## Example
///
/// ```gleam
/// /// Two round trips, then done.
/// pub fn proof() -> Dual(
///   patterns.Request(String, Int, patterns.Request(String, Int, core.Done)),
///   patterns.Serve(String, Int, patterns.Serve(String, Int, core.Done)),
/// ) {
///   patterns.request(patterns.request(duality.done()))
/// }
/// ```
///
pub fn request(
  then: Dual(a, b),
) -> Dual(Request(question, answer, a), Serve(question, answer, b)) {
  duality.send(duality.receive(then))
}

/// Witness that a `Serve` faces a `Request`. The mirror of `request`.
///
/// ## Example
///
/// ```gleam
/// let proof = patterns.serve(duality.done())
/// ```
///
pub fn serve(
  then: Dual(a, b),
) -> Dual(Serve(question, answer, a), Request(question, answer, b)) {
  duality.receive(duality.send(then))
}

// Proposal and decision

/// Send a proposal, then follow whichever way the other side decides.
///
/// The two outcomes are separate continuations, so accepting and rejecting can
/// lead to genuinely different protocols rather than to the same one carrying
/// a flag. Its dual is `Decide`.
///
/// ## Example
///
/// ```gleam
/// /// Offer a price. If they take it, settle up; if not, we are done.
/// pub type Haggle =
///   patterns.Propose(Price, patterns.Request(Card, Receipt, core.Done), core.Done)
/// ```
///
pub type Propose(proposal, accepted, rejected) =
  core.Send(proposal, core.Offer(accepted, rejected))

/// Take a proposal, then decide which way the protocol goes.
/// The dual of `Propose`.
///
pub type Decide(proposal, accepted, rejected) =
  core.Recv(proposal, core.Choose(accepted, rejected))

/// Witness that a `Propose` faces a `Decide`.
///
/// Both outcomes need their own proof, which is what stops one side from
/// planning for a branch the other cannot take.
///
/// ## Example
///
/// ```gleam
/// let proof = patterns.propose(patterns.request(duality.done()), duality.done())
/// ```
///
pub fn propose(
  accepted: Dual(a, b),
  rejected: Dual(c, d),
) -> Dual(Propose(proposal, a, c), Decide(proposal, b, d)) {
  duality.send(duality.offer(accepted, rejected))
}

/// Witness that a `Decide` faces a `Propose`. The mirror of `propose`.
///
pub fn decide(
  accepted: Dual(a, b),
  rejected: Dual(c, d),
) -> Dual(Decide(proposal, a, c), Propose(proposal, b, d)) {
  duality.receive(duality.choose(accepted, rejected))
}

// Two-phase commit

/// Propose a transaction, collect the vote, announce the outcome, then
/// continue. The coordinator's half of two-phase commit.
///
/// The outcome is sent unconditionally rather than as a branch, because both
/// commit and abort leave the participant in the same place: waiting for
/// whatever the coordinator does next. Reach for `Propose` when the two
/// outcomes really do lead somewhere different.
///
/// ## Example
///
/// ```gleam
/// pub type Coordinator =
///   patterns.Coordinate(Transaction, Vote, Outcome, core.Done)
/// ```
///
pub type Coordinate(proposal, vote, outcome, then) =
  core.Send(proposal, core.Recv(vote, core.Send(outcome, then)))

/// Take a proposal, vote on it, take the outcome, then continue.
/// The participant's half of two-phase commit, and the dual of `Coordinate`.
///
pub type Participate(proposal, vote, outcome, then) =
  core.Recv(proposal, core.Send(vote, core.Recv(outcome, then)))

/// Witness that a `Coordinate` faces a `Participate`.
///
/// ## Example
///
/// ```gleam
/// /// Two rounds of two-phase commit over the same channel.
/// let proof = patterns.coordinate(patterns.coordinate(duality.done()))
/// ```
///
pub fn coordinate(
  then: Dual(a, b),
) -> Dual(
  Coordinate(proposal, vote, outcome, a),
  Participate(proposal, vote, outcome, b),
) {
  duality.send(duality.receive(duality.send(then)))
}

/// Witness that a `Participate` faces a `Coordinate`. The mirror of
/// `coordinate`.
///
pub fn participate(
  then: Dual(a, b),
) -> Dual(
  Participate(proposal, vote, outcome, a),
  Coordinate(proposal, vote, outcome, b),
) {
  duality.receive(duality.send(duality.receive(then)))
}
