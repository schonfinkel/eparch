//// Deciding duality, equivalence and subtyping between projected protocols.
////
//// `eparch/session/duality` proves two protocols fit together by building a
//// value out of combinators. That works, and it is checked by the compiler,
//// which is why it is the right tool for a protocol written as a nested type.
//// It also has a hard limit: a finite value cannot witness an infinite
//// unfolding, so the moment a protocol repeats there is no proof to build.
////
//// This module is the answer for those. Once a protocol is a state graph
//// rather than a type, the questions stop being about syntax and start being
//// about behaviour, and behavioural questions are answered coinductively:
//// instead of building a proof upward from the leaves, assume the pair of
//// states you care about is related, and look for a contradiction. If none
//// turns up before you run out of pairs, there was never going to be one.
////
//// Keizer, Basold and Pérez set this out in [Session Coalgebras: A Coalgebraic View on Session Types and Communication Protocols (2020)](https://arxiv.org/pdf/2011.05712)
//// part that makes it practical is their Theorem 1: for a coalgebra with
//// finitely many reachable states, all three relations are **decidable**. A
//// projected graph always has finitely many states, so all three are decidable
//// here, and the procedure is small enough to read.
////
//// ## The procedure
////
//// Start with the pair of initial states. Repeatedly take a pair, check the
//// two states carry compatible labels, and add whatever pairs their matching
//// transitions lead to. Stop when a check fails, or when every pair has been
//// visited. Termination is free: there are at most `left * right` pairs and
//// none is ever visited twice.
////
//// What comes back on success is the relation itself, because that is the
//// certificate. A bisimulation is not evidence *for* equivalence, it is what
//// equivalence means.
////
//// ## The three relations
////
//// **Duality** asks whether two participants fit together: every send meets a
//// receive of the same thing, every choice meets an offer of the same arms,
//// and both finish together. This is the recursive counterpart of
//// `session/duality`.
////
//// **Equivalence** asks whether two protocols are the same protocol. Useful
//// for checking that an edit to a specification changed nothing, and for
//// telling a genuine redesign from a renaming.
////
//// **Subtyping** asks whether one protocol may stand in for another, and is
//// capability the nested encoding has none of. `subtype(new, old)` succeeding
//// means a participant written against `old` keeps working against `new`, so
//// it is the check to run before shipping a protocol change. The rule is the
//// usual one: a subtype may **offer more** than it was asked to, because being
//// ready for a message nobody sends costs nothing, and may **select fewer**,
//// because declining to use an option strands nobody. Widening in the other
//// direction breaks callers, and gets rejected here rather than in production.
////
//// ## Limits
////
//// Payload types are compared by name, because a specification holds names
//// rather than types. Two payloads spelled differently are treated as
//// different even when one is an alias for the other, which errs toward
//// rejecting a change that is in fact safe.
////
//// A send is never related to a choice, even a choice with one arm, and the
//// projector cannot produce a one-armed choice anyway. Nothing is lost, but it
//// does mean these relations are slightly finer than the ones in the paper.
////

import eparch/protocol/graph.{type Action, type Graph}
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// The relation that was found, which is the certificate that the check
/// succeeded rather than a report about it.
///
/// Pairs are `#(left state, right state)`, in the order they were reached.
///
pub type Witness {
  Witness(pairs: List(#(String, String)))
}

/// Where two protocols stopped being related, and why.
///
pub type Mismatch {
  Mismatch(left: String, right: String, reason: Reason)
}

/// Why a pair of states failed to relate.
///
pub type Reason {
  /// One transmits where the other receives, or one is finished where the
  /// other is not.
  Incompatible(left: String, right: String)
  /// The same position, a different message.
  DifferentLabels(left: String, right: String)
  /// The same message, a different payload type.
  DifferentPayloads(label: String, left: String, right: String)
  /// The same message, a different participant at the other end.
  DifferentPeers(left: String, right: String)
  /// A branch one side can take and the other cannot handle.
  UnmatchedBranch(label: String)
  /// A graph referred to a state it does not have.
  UnknownState(name: String)
}

/// Do these two participants fit together?
///
/// Every send has to meet a receive of the same message, every choice an offer
/// of exactly the same arms, and both sides have to finish together. This is
/// what `session/duality` proves for a protocol written as a nested type, and
/// unlike that one it holds for protocols that repeat.
///
/// ## Example
///
/// ```gleam
/// let assert Ok([customer, teller]) = graph.compile(atm())
/// let assert Ok(_) = relations.dual(customer, teller)
/// ```
///
pub fn dual(left: Graph, right: Graph) -> Result(Witness, Mismatch) {
  decide(left, right, opposed(left.role, right.role))
}

/// Are these two the same protocol?
///
/// Bisimulation, so a renaming of states relates but a change to what is sent
/// does not.
///
/// ## Example
///
/// ```gleam
/// // Did tidying the specification change the protocol?
/// let assert Ok(_) = relations.equivalent(before, after)
/// ```
///
pub fn equivalent(left: Graph, right: Graph) -> Result(Witness, Mismatch) {
  decide(left, right, identical)
}

/// May `sub` be used everywhere `sup` was expected?
///
/// The check to run before changing a published protocol: if
/// `subtype(new, old)` succeeds, every participant written against the old one
/// still works.
///
/// `sub` may offer branches `sup` never mentioned, and may select fewer than
/// `sup` allowed. It may not do the reverse, because either direction of that
/// strands somebody: selecting an arm the other side cannot handle, or
/// refusing to handle one it is entitled to send.
///
/// ## Example
///
/// ```gleam
/// let assert Ok([_, new_teller]) = graph.compile(atm_with_transfers())
/// let assert Ok([_, old_teller]) = graph.compile(atm())
///
/// // Handling a new request is safe. Requiring one would not be.
/// let assert Ok(_) = relations.subtype(new_teller, old_teller)
/// ```
///
pub fn subtype(sub: Graph, sup: Graph) -> Result(Witness, Mismatch) {
  decide(sub, sup, simulated)
}

// THE PROCEDURE
//
// One worklist, three comparisons. A comparison reports why a pair does not
// relate, or hands back the pairs that have to relate for this one to.

type Compare =
  fn(Action, Action) -> Result(List(#(String, String)), Reason)

fn decide(
  left: Graph,
  right: Graph,
  compare: Compare,
) -> Result(Witness, Mismatch) {
  advance(left, right, compare, [#(left.initial, right.initial)], set.new(), [])
}

fn advance(
  left: Graph,
  right: Graph,
  compare: Compare,
  frontier: List(#(String, String)),
  seen: Set(#(String, String)),
  order: List(#(String, String)),
) -> Result(Witness, Mismatch) {
  case frontier {
    // No pair left to contradict, so the relation is closed under transitions
    // and there was never going to be a contradiction. This is the fixpoint.
    [] -> Ok(Witness(pairs: list.reverse(order)))

    [pair, ..rest] ->
      case set.contains(seen, pair) {
        // Already assumed related, which is how a protocol that repeats gets
        // an answer at all: the cycle is tied off rather than unfolded.
        True -> advance(left, right, compare, rest, seen, order)

        False -> {
          let #(here, there) = pair
          use this <- result.try(look_up(left, here, pair))
          use that <- result.try(look_up(right, there, pair))

          case compare(this, that) {
            Error(reason) -> Error(Mismatch(left: here, right: there, reason:))
            Ok(next) ->
              advance(
                left,
                right,
                compare,
                list.append(next, rest),
                set.insert(seen, pair),
                [pair, ..order],
              )
          }
        }
      }
  }
}

fn look_up(
  g: Graph,
  name: String,
  pair: #(String, String),
) -> Result(Action, Mismatch) {
  case graph.state(g, name) {
    Ok(state) -> Ok(state.action)
    Error(Nil) ->
      Error(Mismatch(left: pair.0, right: pair.1, reason: UnknownState(name:)))
  }
}

// DUALITY

fn opposed(left_role: String, right_role: String) -> Compare {
  fn(this: Action, that: Action) {
    case this, that {
      graph.Done, graph.Done -> Ok([])

      graph.Sends(to:, label:, payload:, next:),
        graph.Receives(
          from:,
          label: their_label,
          payload: their_payload,
          next: their_next,
        )
      -> {
        use _ <- result.try(same_peers(to, right_role, from, left_role))
        use _ <- result.try(same_message(
          label,
          their_label,
          payload,
          their_payload,
        ))
        Ok([#(next, their_next)])
      }

      graph.Receives(from:, label:, payload:, next:),
        graph.Sends(
          to:,
          label: their_label,
          payload: their_payload,
          next: their_next,
        )
      -> {
        use _ <- result.try(same_peers(from, right_role, to, left_role))
        use _ <- result.try(same_message(
          label,
          their_label,
          payload,
          their_payload,
        ))
        Ok([#(next, their_next)])
      }

      graph.Selects(to:, arms:), graph.Offers(from:, arms: theirs) -> {
        use _ <- result.try(same_peers(to, right_role, from, left_role))
        exactly(arms, theirs)
      }

      graph.Offers(from:, arms:), graph.Selects(to:, arms: theirs) -> {
        use _ <- result.try(same_peers(from, right_role, to, left_role))
        exactly(arms, theirs)
      }

      _, _ -> Error(Incompatible(describe(this), describe(that)))
    }
  }
}

/// Duality is exact in both directions: an arm one side can take and the other
/// cannot handle is a deadlock, and an arm nobody can take is dead protocol.
fn exactly(
  arms: List(graph.Arm),
  theirs: List(graph.Arm),
) -> Result(List(#(String, String)), Reason) {
  use _ <- result.try(covered(theirs, arms))
  paired(arms, theirs)
}

// EQUIVALENCE

fn identical(
  this: Action,
  that: Action,
) -> Result(List(#(String, String)), Reason) {
  case this, that {
    graph.Done, graph.Done -> Ok([])

    graph.Sends(to:, label:, payload:, next:),
      graph.Sends(
        to: their_to,
        label: their_label,
        payload: their_payload,
        next: their_next,
      )
    -> {
      use _ <- result.try(same_peer(to, their_to))
      use _ <- result.try(same_message(
        label,
        their_label,
        payload,
        their_payload,
      ))
      Ok([#(next, their_next)])
    }

    graph.Receives(from:, label:, payload:, next:),
      graph.Receives(
        from: their_from,
        label: their_label,
        payload: their_payload,
        next: their_next,
      )
    -> {
      use _ <- result.try(same_peer(from, their_from))
      use _ <- result.try(same_message(
        label,
        their_label,
        payload,
        their_payload,
      ))
      Ok([#(next, their_next)])
    }

    graph.Selects(to:, arms:), graph.Selects(to: their_to, arms: theirs) -> {
      use _ <- result.try(same_peer(to, their_to))
      use _ <- result.try(covered(theirs, arms))
      paired(arms, theirs)
    }

    graph.Offers(from:, arms:), graph.Offers(from: their_from, arms: theirs) -> {
      use _ <- result.try(same_peer(from, their_from))
      use _ <- result.try(covered(theirs, arms))
      paired(arms, theirs)
    }

    _, _ -> Error(Incompatible(describe(this), describe(that)))
  }
}

// SUBTYPING

fn simulated(
  sub: Action,
  sup: Action,
) -> Result(List(#(String, String)), Reason) {
  case sub, sup {
    // Offering more than was asked for is safe: being ready for a message
    // nobody sends costs nothing. So every arm the supertype offers has to be
    // present here, and any extra ones are this side's business.
    graph.Offers(from:, arms:), graph.Offers(from: their_from, arms: theirs) -> {
      use _ <- result.try(same_peer(from, their_from))
      paired(theirs, arms)
    }

    // Selecting fewer than was allowed is safe: declining to use an option
    // strands nobody. So every arm this side can take has to be one the
    // supertype already permitted.
    graph.Selects(to:, arms:), graph.Selects(to: their_to, arms: theirs) -> {
      use _ <- result.try(same_peer(to, their_to))
      paired(arms, theirs)
    }

    // Everything else has to match, because there is no room to vary a single
    // message without the other side noticing.
    _, _ -> identical(sub, sup)
  }
}

// COMPARISONS

/// Pair up arms by label, driven by `wanted`. Every label in `wanted` has to
/// appear in `available`, with the same payload.
fn paired(
  wanted: List(graph.Arm),
  available: List(graph.Arm),
) -> Result(List(#(String, String)), Reason) {
  list.try_map(wanted, fn(arm) {
    case list.find(available, fn(other) { other.label == arm.label }) {
      Error(Nil) -> Error(UnmatchedBranch(arm.label))
      Ok(other) ->
        case other.payload == arm.payload {
          False ->
            Error(DifferentPayloads(
              label: arm.label,
              left: arm.payload,
              right: other.payload,
            ))
          True -> Ok(#(arm.next, other.next))
        }
    }
  })
}

/// Every label in `these` appears in `those`.
fn covered(
  these: List(graph.Arm),
  those: List(graph.Arm),
) -> Result(Nil, Reason) {
  list.try_each(these, fn(arm) {
    case list.any(those, fn(other) { other.label == arm.label }) {
      True -> Ok(Nil)
      False -> Error(UnmatchedBranch(arm.label))
    }
  })
}

fn same_message(
  label: String,
  their_label: String,
  payload: String,
  their_payload: String,
) -> Result(Nil, Reason) {
  case label == their_label, payload == their_payload {
    False, _ -> Error(DifferentLabels(left: label, right: their_label))
    _, False ->
      Error(DifferentPayloads(label:, left: payload, right: their_payload))
    True, True -> Ok(Nil)
  }
}

fn same_peer(peer: String, their_peer: String) -> Result(Nil, Reason) {
  case peer == their_peer {
    True -> Ok(Nil)
    False -> Error(DifferentPeers(left: peer, right: their_peer))
  }
}

/// For duality the peers have to be each other, not merely equal: what one
/// side sends to the other is what the other has to be receiving from it.
fn same_peers(
  peer: String,
  expected: String,
  their_peer: String,
  their_expected: String,
) -> Result(Nil, Reason) {
  case peer == expected, their_peer == their_expected {
    True, True -> Ok(Nil)
    False, _ -> Error(DifferentPeers(left: peer, right: expected))
    _, False -> Error(DifferentPeers(left: their_peer, right: their_expected))
  }
}

fn describe(action: Action) -> String {
  case action {
    graph.Sends(to:, label:, ..) -> "sends `" <> label <> "` to " <> to
    graph.Receives(from:, label:, ..) ->
      "receives `" <> label <> "` from " <> from
    graph.Selects(to:, ..) -> "chooses, and tells " <> to
    graph.Offers(from:, ..) -> "waits for " <> from <> " to choose"
    graph.Done -> "is finished"
  }
}

/// Render a mismatch as a line suitable for a terminal.
///
pub fn explain(mismatch: Mismatch) -> String {
  let Mismatch(left:, right:, reason:) = mismatch
  let where = " (at " <> left <> " against " <> right <> ")"

  case reason {
    Incompatible(left: this, right: that) ->
      "one " <> this <> " where the other " <> that <> where
    DifferentLabels(left: this, right: that) ->
      "one sends `"
      <> this
      <> "` where the other expects `"
      <> that
      <> "`"
      <> where
    DifferentPayloads(label:, left: this, right: that) ->
      "`"
      <> label
      <> "` carries "
      <> this
      <> " on one side and "
      <> that
      <> " on the other"
      <> where
    DifferentPeers(left: this, right: that) ->
      "one talks to " <> this <> " where the other talks to " <> that <> where
    UnmatchedBranch(label:) ->
      "branch `" <> label <> "` has nothing to match it" <> where
    UnknownState(name:) -> "no state called `" <> name <> "`" <> where
  }
}

/// The pairs a witness holds, rendered for reading.
///
/// A witness is usually only interesting when a check unexpectedly passed and
/// you want to see which states it decided were related.
///
pub fn render(witness: Witness) -> String {
  witness.pairs
  |> list.map(fn(pair) { pair.0 <> " ~ " <> pair.1 })
  |> string.join("\n")
}
