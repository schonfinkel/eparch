//// Weaving two protocols into one, guided by their contact points.
////
//// Sequencing puts one protocol after another, which is type application and
//// needs nothing from this module. Weaving is the other thing: two protocols
//// that have to advance *in step*, each constraining the other in both
//// directions. A banking service and the authentication it depends on are the
//// standard example. The login has to precede the menu, and each payment needs
//// its own second factor, so neither protocol can simply be appended to the
//// other.
////
//// This is an attempt to implement some ideas from Bocchi, Orchard and Voinea's
//// [A Theory of Composing Protocols (2022)](https://arxiv.org/pdf/2203.02461)
//// Their prefix actions are a parameter of the theory, so instantiating them 
//// with `spec.Message` is within what the paper covers, and the output is one 
//// ordinary `spec.Spec` that projects and checks like any other.
////
//// ## Composition is a relation, not a function
////
//// Two protocols may have no valid interleaving, one, or many. That is not a
//// deficiency to be smoothed over by picking a winner: which weaving is
//// *wanted* is a question about the domain, and nothing here can answer it. So
//// `compose` returns candidates, ranked, and the way to narrow them is to add
//// contact points rather than to guess.
////
//// The paper's own figures are worth knowing before running this on something
//// large. Their suite mostly yields one or two candidates, but an example with
//// nested recursion reaches fourteen. `Options.limit` bounds the search, and
//// `Composition.truncated` says when it bit.
////
//// ## Contact points
////
//// `Assert` introduces a guarantee, `Require` demands one and leaves it, and
//// `Consume` demands one and spends it. They are what turn an intractable set
//// of interleavings into a useful one.
////
//// ```gleam
//// // Payment first, then dispatch. Not the other way round.
//// let paying = spec.Message("Buyer", "Shop", "pay", "Money", spec.Assert("paid", spec.End))
//// let sending = spec.Consume("paid", spec.Message("Shop", "Buyer", "item", "Link", spec.End))
////
//// let assert weave.Composition(candidates: [only], ..) =
////   weave.compose(paying, sending, weave.defaults())
//// ```
////
//// Without the annotations there are two interleavings and no reason to prefer
//// either. With them there is exactly one, and it is the right one.
////
//// ## Branching
////
//// How a choice composes is the one knob worth understanding, because the
//// strict reading returns nothing surprisingly often.
////
//// - `Strong` composes the other protocol into *every* arm. Correct, and
////   frequently empty: an authentication protocol that grants access in one arm
////   and refuses in the other cannot compose the service into the refusing arm,
////   because the guarantee it needs was never asserted there.
//// - `Weak` lets an arm go uncomposed when it genuinely cannot compose, which
////   is exactly the authentication case. At least one arm still has to compose,
////   so neither protocol can be dropped altogether.
//// - `Correlating` pairs each arm of one protocol with the arms of the other it
////   can compose with, rather than distributing into all of them. This is what
////   you want when two choices are meant to line up, such as a service choice
////   and a matching payment method.
//// - `All` permits both relaxations.
////
//// Each relaxation *widens* the result set rather than narrowing it, so a
//// candidate derivable strongly is still derivable under `All`. Every candidate
//// records which relaxations its derivation needed, and that is what the
//// ranking is built on: candidates needing none come first.
////
//// ## What this does not do
////
//// Composition drops the cosmetic state names `spec.At` carries, because a
//// woven protocol's states do not correspond to either input's.
////
//// Nothing here checks that the result is *projectable*. Weaving can easily
//// produce a protocol some participant cannot follow, and
//// `graph.compile` is what says so. Run it on the candidate you pick.
////

import eparch/protocol/graph
import eparch/protocol/spec.{type Protocol, type Spec}
import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string

/// How much freedom the search has when it meets a choice.
///
/// Ordered from strictest to loosest. Each admits everything the ones before it
/// do, so widening never loses a candidate.
///
pub type Branching {
  /// Compose the other protocol into every arm. The reading with no
  /// relaxations, and the one that most often returns nothing.
  Strong
  /// Allow an arm that cannot compose to stand alone, as long as at least one
  /// arm does compose. This is the authentication case.
  Weak
  /// Pair each arm with the arms of the other protocol it can compose with,
  /// instead of distributing into all of them.
  Correlating
  /// Both relaxations.
  All
}

/// A liberty a derivation had to take.
///
/// Empty means the candidate is derivable under `Strong`, which is the
/// strongest thing that can be said about a weaving.
///
pub type Relaxation {
  /// This arm could not compose, and was left as it was.
  WeakBranch(label: String)
  /// These two arms were paired off rather than distributed into each other.
  CorrelatedBranch(left: String, right: String)
}

/// One way of weaving the two protocols together.
///
pub type Candidate {
  Candidate(protocol: Spec, relaxations: List(Relaxation))
}

/// Every weaving the search found, best first.
///
pub type Composition {
  Composition(candidates: List(Candidate), truncated: Bool)
}

/// What to allow, and how hard to look.
///
pub type Options {
  Options(
    branching: Branching,
    /// Guarantees the surrounding context already provides. Usually empty:
    /// starting with something in hand means the protocols are not required to
    /// establish it between them.
    given: List(String),
    /// Ceiling on candidates carried through any one step of the search.
    /// Reached only by protocols with nested recursion in practice.
    limit: Int,
  )
}

/// Strong branching, nothing granted, a limit that is generous for anything
/// hand-written.
///
pub fn defaults() -> Options {
  Options(branching: Strong, given: [], limit: 64)
}

/// Weave two protocols together, returning every valid interleaving.
///
/// ## Example
///
/// ```gleam
/// let options = weave.Options(..weave.defaults(), branching: weave.Weak)
/// let weave.Composition(candidates:, truncated: _) =
///   weave.compose(banking, authentication, options)
///
/// case candidates {
///   [] -> io.println("no valid interleaving; try adding contact points")
///   [best, ..] -> chosen(best.protocol)
/// }
/// ```
///
pub fn compose(left: Spec, right: Spec, options: Options) -> Composition {
  let found =
    search(
      left,
      right,
      Env(left: [], right: [], given: set.from_list(options.given)),
      options,
    )

  Composition(candidates: rank(found.items), truncated: found.truncated)
}

/// Weave two whole protocols, keeping the participants and imports of both.
///
/// A convenience over `compose` for the common case. The candidates come back
/// ranked, and each is an ordinary protocol, so `graph.compile` is the next
/// call. It has to be: weaving can produce a protocol that no longer projects.
///
/// ## Example
///
/// ```gleam
/// let assert [best, ..] = weave.interleave(banking, authentication, options)
/// let assert Ok(graphs) = graph.compile(best)
/// ```
///
pub fn interleave(
  left: Protocol,
  right: Protocol,
  options: Options,
) -> List(Protocol) {
  let Composition(candidates:, truncated: _) =
    compose(left.spec, right.spec, options)

  list.map(candidates, fn(candidate) {
    spec.Protocol(
      name: left.name <> "_" <> right.name,
      roles: list.unique(list.append(left.roles, right.roles)),
      initial: left.initial,
      imports: list.unique(list.append(left.imports, right.imports)),
      spec: candidate.protocol,
    )
  })
}

/// Render a relaxation as a line suitable for a terminal.
///
pub fn describe(relaxation: Relaxation) -> String {
  case relaxation {
    WeakBranch(label:) ->
      "arm `" <> label <> "` could not compose and was left as it was"
    CorrelatedBranch(left:, right:) ->
      "arm `" <> left <> "` was paired with arm `" <> right <> "`"
  }
}

// THE SEARCH
//
// One function per rule of the paper's Figure 2, and a symmetry step in
// `derive` that stands in for its [sym] rule. Symmetry is applied by trying
// both protocols in the leading position rather than as a rule of its own,
// because a rule that only swaps its arguments would not terminate.

/// The two recursion environments and the assertions in scope.
///
/// A variable is `used` once it has been merged with a recursion on the other
/// side, which is what stops nested recursions being flattened into each other.
type Env {
  Env(left: List(Var), right: List(Var), given: Set(String))
}

type Var {
  Var(name: String, used: Bool)
}

type Draft {
  Draft(spec: Spec, relaxations: List(Relaxation))
}

/// Candidates, and whether the limit cut any off.
type Drafts {
  Drafts(items: List(Draft), truncated: Bool)
}

fn search(left: Spec, right: Spec, env: Env, options: Options) -> Drafts {
  case left, right {
    // [end]
    spec.End, spec.End -> single(spec.End)

    // [call]. Both sides have to have reached the *same* variable, which is
    // only true once a pair of recursions has been merged. That is what stops
    // a recursive protocol swallowing a non-recursive one.
    spec.Continue(here), spec.Continue(there) if here == there ->
      case bound(env, here) {
        True -> single(spec.Continue(here))
        False -> nothing()
      }

    _, _ ->
      concat(
        lead(left, right, env, options),
        lead(right, left, swap(env), options),
      )
      |> cap(options.limit)
  }
}

/// Apply whichever rule consumes the head of the leading protocol.
fn lead(left: Spec, right: Spec, env: Env, options: Options) -> Drafts {
  case left {
    // Cosmetic naming, dropped: a woven protocol's states correspond to
    // neither input's.
    spec.At(name: _, then:) -> lead(then, right, env, options)

    // [act]
    spec.Message(from:, to:, label:, payload:, then:) ->
      search(then, right, env, options)
      |> rebuild(fn(rest) {
        spec.Message(from:, to:, label:, payload:, then: rest)
      })

    // [assert]
    spec.Assert(name:, then:) ->
      search(then, right, granting(env, name), options)
      |> rebuild(fn(rest) { spec.Assert(name:, then: rest) })

    // [require]. The guarantee has to be in scope, and stays there.
    spec.Require(name:, then:) ->
      case set.contains(env.given, name) {
        False -> nothing()
        True ->
          search(then, right, env, options)
          |> rebuild(fn(rest) { spec.Require(name:, then: rest) })
      }

    // [consume]. The guarantee has to be in scope, and is spent.
    spec.Consume(name:, then:) ->
      case set.contains(env.given, name) {
        False -> nothing()
        True ->
          search(then, right, spending(env, name), options)
          |> rebuild(fn(rest) { spec.Consume(name:, then: rest) })
      }

    spec.Choice(at:, to:, branches:) ->
      branch(at, to, branches, right, env, options)

    spec.Loop(name:, body:) -> recur(name, body, right, env, options)

    // Both only appear as base cases, handled in `derive`. Reaching them here
    // means the other protocol still has work to do and this one cannot help.
    spec.Continue(_) -> nothing()
    spec.End -> nothing()
  }
}

// BRANCHING

fn branch(
  at: String,
  to: String,
  branches: List(spec.Branch),
  right: Spec,
  env: Env,
  options: Options,
) -> Drafts {
  // Each arm composed against the whole of the other protocol, computed once
  // and shared by the strong and weak rules.
  let attempts =
    list.map(branches, fn(arm) { #(arm, search(arm.then, right, env, options)) })

  let strong = strong_branch(at, to, attempts, options)

  let weak = case options.branching {
    Weak | All -> weak_branch(at, to, attempts, env, options)
    Strong | Correlating -> nothing()
  }

  let correlating = case options.branching, right {
    Correlating, spec.Choice(at: their_at, to: their_to, branches: theirs)
    | All, spec.Choice(at: their_at, to: their_to, branches: theirs)
    ->
      correlating_branch(
        at,
        to,
        branches,
        their_at,
        their_to,
        theirs,
        env,
        options,
      )
    _, _ -> nothing()
  }

  concat(strong, concat(weak, correlating))
}

/// [bra]. Every arm has to compose, and the result takes one derivation from
/// each, so the count is the product across arms.
fn strong_branch(
  at: String,
  to: String,
  attempts: List(#(spec.Branch, Drafts)),
  options: Options,
) -> Drafts {
  case list.any(attempts, fn(attempt) { list.is_empty({ attempt.1 }.items) }) {
    True -> nothing()
    False ->
      attempts
      |> list.map(fn(attempt) { #({ attempt.0 }, { attempt.1 }) })
      |> product(options.limit)
      |> rebuild_arms(at, to)
  }
}

/// [wbra]. Arms that cannot compose are left alone, provided at least one arm
/// does compose and every uncomposed arm stands up on its own.
///
/// Which arms those are is not a choice the search makes: an arm is left alone
/// exactly when composing it fails, so there is one weak derivation per set of
/// composable arms rather than one per partition.
fn weak_branch(
  at: String,
  to: String,
  attempts: List(#(spec.Branch, Drafts)),
  env: Env,
  options: Options,
) -> Drafts {
  let #(composed, alone) =
    list.partition(attempts, fn(attempt) { !list.is_empty({ attempt.1 }.items) })

  // With nothing left alone this is just [bra], already derived above. With
  // nothing composed, one of the protocols never happens at all.
  case list.is_empty(alone) || list.is_empty(composed) {
    True -> nothing()
    False ->
      case
        list.all(alone, fn(attempt) {
          graph.well_asserted({ attempt.0 }.then, given: set.to_list(env.given))
        })
      {
        False -> nothing()
        True ->
          attempts
          |> list.map(fn(attempt) {
            let arm = attempt.0
            case list.is_empty({ attempt.1 }.items) {
              // Left as it was, and recorded as the liberty it is.
              True -> #(
                arm,
                Drafts(
                  items: [
                    Draft(spec: arm.then, relaxations: [WeakBranch(arm.label)]),
                  ],
                  truncated: False,
                ),
              )
              False -> #(arm, attempt.1)
            }
          })
          |> product(options.limit)
          |> rebuild_arms(at, to)
      }
  }
}

/// [cbra]. Each arm of one protocol is paired with the arms of the other it can
/// compose with, and the result nests the second choice inside the first.
///
/// Every arm on both sides has to take part, which is what stops a correlation
/// quietly dropping half of one protocol.
fn correlating_branch(
  at: String,
  to: String,
  branches: List(spec.Branch),
  their_at: String,
  their_to: String,
  theirs: List(spec.Branch),
  env: Env,
  options: Options,
) -> Drafts {
  let pairings =
    list.map(branches, fn(arm) {
      let matches =
        list.filter_map(theirs, fn(other) {
          let found = search(arm.then, other.then, env, options)
          case list.is_empty(found.items) {
            True -> Error(Nil)
            False -> Ok(#(other, found))
          }
        })
      #(arm, matches)
    })

  let every_arm_pairs =
    list.all(pairings, fn(pairing) { !list.is_empty(pairing.1) })

  let paired_with_us =
    pairings
    |> list.flat_map(fn(pairing) {
      list.map(pairing.1, fn(match) { { match.0 }.label })
    })
    |> list.unique

  let every_arm_of_theirs_pairs =
    list.all(theirs, fn(other) { list.contains(paired_with_us, other.label) })

  case every_arm_pairs && every_arm_of_theirs_pairs {
    False -> nothing()
    True ->
      pairings
      |> list.map(fn(pairing) {
        let arm = pairing.0
        let inner =
          pairing.1
          |> list.map(fn(match) {
            let other = match.0
            #(
              spec.Branch(
                label: other.label,
                payload: other.payload,
                then: spec.End,
              ),
              { match.1 }
                |> note(CorrelatedBranch(left: arm.label, right: other.label)),
            )
          })
          |> product(options.limit)
          |> rebuild_arms(their_at, their_to)

        #(arm, inner)
      })
      |> product(options.limit)
      |> rebuild_arms(at, to)
  }
}

// COMBINING
//
// A branching rule needs one derivation from every arm, so the arms have to be
// multiplied out. `Rows` is that product part way through, and it carries the
// truncation flag so a limit reached deep in the search is still reported.

type Rows {
  Rows(items: List(#(List(spec.Branch), List(Relaxation))), truncated: Bool)
}

fn product(attempts: List(#(spec.Branch, Drafts)), limit: Int) -> Rows {
  list.fold(
    attempts,
    Rows(items: [#([], [])], truncated: False),
    fn(rows, attempt) {
      let #(arm, drafts) = attempt

      let items =
        list.flat_map(rows.items, fn(row) {
          list.map(drafts.items, fn(draft) {
            #(
              [
                spec.Branch(
                  label: arm.label,
                  payload: arm.payload,
                  then: draft.spec,
                ),
                ..row.0
              ],
              list.append(row.1, draft.relaxations),
            )
          })
        })

      let truncated = rows.truncated || drafts.truncated
      case list.length(items) > limit {
        True -> Rows(items: list.take(items, limit), truncated: True)
        False -> Rows(items:, truncated:)
      }
    },
  )
}

fn rebuild_arms(rows: Rows, at: String, to: String) -> Drafts {
  Drafts(
    items: list.map(rows.items, fn(row) {
      Draft(spec: choice(at, to, list.reverse(row.0)), relaxations: row.1)
    }),
    truncated: rows.truncated,
  )
}

/// A choice with one arm is a message with a label, and saying so keeps the
/// output projectable. Correlating branching produces these routinely.
fn choice(at: String, to: String, branches: List(spec.Branch)) -> Spec {
  case branches {
    [spec.Branch(label:, payload:, then:)] ->
      spec.Message(from: at, to:, label:, payload:, then:)
    _ -> spec.Choice(at:, to:, branches:)
  }
}

// RECURSION
//
// The three rules that let two repeating protocols become one. The awkwardness
// here is all in service of one thing: two recursions merge into a single loop,
// and nested recursions must not collapse into each other.

fn recur(
  name: String,
  body: Spec,
  right: Spec,
  env: Env,
  options: Options,
) -> Drafts {
  concat(
    rec1(name, body, right, env, options),
    concat(rec2(name, body, right, env, options), rec3(name, body, right, env)),
  )
}

/// [rec1]. Open a loop on this side and keep the other protocol whole, so the
/// two bodies are composed and only one binder survives.
fn rec1(
  name: String,
  body: Spec,
  right: Spec,
  env: Env,
  options: Options,
) -> Drafts {
  case right {
    spec.Loop(..) -> {
      let opened =
        Env(..env, left: list.append(env.left, [Var(name:, used: False)]))

      search(body, right, opened, options)
      |> rebuild(fn(rest) { spec.Loop(name:, body: rest) })
      |> only(fn(woven) {
        graph.well_asserted(woven, given: set.to_list(env.given))
      })
    }
    _ -> nothing()
  }
}

/// [rec2]. Close the merge: this side's binder disappears and its variable is
/// redirected at one the other side already opened.
///
/// The variable taken has to be unused, and everything after it in the other
/// side's environment has to be unused too. That condition is what keeps nested
/// recursions from flattening into one another, which would let a protocol
/// repeat something its author wrote once.
fn rec2(
  name: String,
  body: Spec,
  right: Spec,
  env: Env,
  options: Options,
) -> Drafts {
  env.right
  |> mergeable
  |> list.map(fn(target) {
    let #(variable, updated) = target
    search(
      rename(body, from: name, to: variable),
      right,
      Env(..env, right: updated),
      options,
    )
  })
  |> list.fold(nothing(), concat)
}

/// Every variable that could close a merge, with the environment it leaves
/// behind.
fn mergeable(variables: List(Var)) -> List(#(String, List(Var))) {
  variables
  |> list.index_map(fn(variable, index) { #(variable, index) })
  |> list.filter_map(fn(entry) {
    let #(variable, index) = entry
    let after = list.drop(variables, index + 1)

    case variable.used || list.any(after, fn(later) { later.used }) {
      True -> Error(Nil)
      False ->
        Ok(#(
          variable.name,
          list.index_map(variables, fn(each, position) {
            case position == index {
              True -> Var(..each, used: True)
              False -> each
            }
          }),
        ))
    }
  })
}

/// [rec3]. A repeating protocol may only be dropped in once the other one has
/// been used up, or it would repeat actions that were written once.
fn rec3(name: String, body: Spec, right: Spec, env: Env) -> Drafts {
  let whole = spec.Loop(name:, body:)

  case right {
    spec.End ->
      case
        list.is_empty(free_variables(whole, []))
        && graph.well_asserted(whole, given: set.to_list(env.given))
      {
        True -> single(whole)
        False -> nothing()
      }
    _ -> nothing()
  }
}

fn rename(node: Spec, from from: String, to to: String) -> Spec {
  case node {
    spec.Continue(name) if name == from -> spec.Continue(to)
    spec.Continue(_) -> node
    spec.End -> node
    // Shadowed, so anything inside belongs to the inner binder.
    spec.Loop(name:, body: _) if name == from -> node
    spec.Loop(name:, body:) -> spec.Loop(name:, body: rename(body, from:, to:))
    spec.At(name:, then:) -> spec.At(name:, then: rename(then, from:, to:))
    spec.Assert(name:, then:) ->
      spec.Assert(name:, then: rename(then, from:, to:))
    spec.Require(name:, then:) ->
      spec.Require(name:, then: rename(then, from:, to:))
    spec.Consume(name:, then:) ->
      spec.Consume(name:, then: rename(then, from:, to:))
    spec.Message(from: sender, to: recipient, label:, payload:, then:) ->
      spec.Message(
        from: sender,
        to: recipient,
        label:,
        payload:,
        then: rename(then, from:, to:),
      )
    spec.Choice(at:, to: recipient, branches:) ->
      spec.Choice(
        at:,
        to: recipient,
        branches: list.map(branches, fn(arm) {
          spec.Branch(..arm, then: rename(arm.then, from:, to:))
        }),
      )
  }
}

fn free_variables(node: Spec, bound: List(String)) -> List(String) {
  case node {
    spec.Continue(name) ->
      case list.contains(bound, name) {
        True -> []
        False -> [name]
      }
    spec.End -> []
    spec.Loop(name:, body:) -> free_variables(body, [name, ..bound])
    spec.At(name: _, then:) -> free_variables(then, bound)
    spec.Assert(name: _, then:) -> free_variables(then, bound)
    spec.Require(name: _, then:) -> free_variables(then, bound)
    spec.Consume(name: _, then:) -> free_variables(then, bound)
    spec.Message(then:, ..) -> free_variables(then, bound)
    spec.Choice(branches:, ..) ->
      list.flat_map(branches, fn(arm) { free_variables(arm.then, bound) })
  }
}

// RANKING

/// Best first, and each weaving only once.
///
/// The order is by how much the derivation had to be relaxed, because that is
/// the only thing about a candidate this module can honestly judge. Which
/// weaving is *wanted* is a question about the domain.
fn rank(drafts: List(Draft)) -> List(Candidate) {
  drafts
  |> list.sort(fn(left, right) {
    int.compare(list.length(left.relaxations), list.length(right.relaxations))
  })
  |> list.fold([], fn(kept, draft) {
    // The same weaving is reachable by more than one derivation, notably by
    // symmetry, and merging two loops can leave either side's binder standing.
    // Comparing canonically collapses both. Sorting first means the copy kept
    // is the least relaxed one, and it keeps the author's own loop names.
    let seen = canonical(draft.spec, 0)
    case
      list.any(kept, fn(candidate: Candidate) {
        canonical(candidate.protocol, 0) == seen
      })
    {
      True -> kept
      False -> [
        Candidate(protocol: draft.spec, relaxations: draft.relaxations),
        ..kept
      ]
    }
  })
  |> list.reverse
}

/// Bound recursion variables renamed by position, so two weavings that differ
/// only in which binder survived are recognised as one weaving.
fn canonical(node: Spec, depth: Int) -> Spec {
  case node {
    spec.Loop(name:, body:) -> {
      let fresh = "#" <> int.to_string(depth)
      spec.Loop(
        name: fresh,
        body: canonical(rename(body, from: name, to: fresh), depth + 1),
      )
    }
    spec.Continue(_) -> node
    spec.End -> node
    // Cosmetic, and composition drops it anyway. Erasing it here keeps a name
    // that survived on one side only from splitting a duplicate in two.
    spec.At(name: _, then:) -> canonical(then, depth)
    spec.Assert(name:, then:) ->
      spec.Assert(name:, then: canonical(then, depth))
    spec.Require(name:, then:) ->
      spec.Require(name:, then: canonical(then, depth))
    spec.Consume(name:, then:) ->
      spec.Consume(name:, then: canonical(then, depth))
    spec.Message(from:, to:, label:, payload:, then:) ->
      spec.Message(from:, to:, label:, payload:, then: canonical(then, depth))
    spec.Choice(at:, to:, branches:) ->
      spec.Choice(
        at:,
        to:,
        branches: list.map(branches, fn(arm) {
          spec.Branch(..arm, then: canonical(arm.then, depth))
        }),
      )
  }
}

// PLUMBING

fn nothing() -> Drafts {
  Drafts(items: [], truncated: False)
}

fn single(node: Spec) -> Drafts {
  Drafts(items: [Draft(spec: node, relaxations: [])], truncated: False)
}

fn concat(left: Drafts, right: Drafts) -> Drafts {
  Drafts(
    items: list.append(left.items, right.items),
    truncated: left.truncated || right.truncated,
  )
}

fn rebuild(drafts: Drafts, wrap: fn(Spec) -> Spec) -> Drafts {
  Drafts(
    ..drafts,
    items: list.map(drafts.items, fn(draft) {
      Draft(..draft, spec: wrap(draft.spec))
    }),
  )
}

fn note(drafts: Drafts, relaxation: Relaxation) -> Drafts {
  Drafts(
    ..drafts,
    items: list.map(drafts.items, fn(draft) {
      Draft(..draft, relaxations: [relaxation, ..draft.relaxations])
    }),
  )
}

fn only(drafts: Drafts, keep: fn(Spec) -> Bool) -> Drafts {
  Drafts(
    ..drafts,
    items: list.filter(drafts.items, fn(draft) { keep(draft.spec) }),
  )
}

fn cap(drafts: Drafts, limit: Int) -> Drafts {
  case list.length(drafts.items) > limit {
    True -> Drafts(items: list.take(drafts.items, limit), truncated: True)
    False -> drafts
  }
}

fn swap(env: Env) -> Env {
  Env(left: env.right, right: env.left, given: env.given)
}

fn granting(env: Env, name: String) -> Env {
  Env(..env, given: set.insert(env.given, name))
}

fn spending(env: Env, name: String) -> Env {
  Env(..env, given: set.delete(env.given, name))
}

fn bound(env: Env, name: String) -> Bool {
  let named = fn(variable: Var) { variable.name == name }
  list.any(env.left, named) || list.any(env.right, named)
}

/// Render a candidate's relaxations as a line suitable for a terminal.
///
pub fn summarise(candidate: Candidate) -> String {
  case candidate.relaxations {
    [] -> "derivable with strong branching"
    relaxations ->
      relaxations
      |> list.map(describe)
      |> string.join("; ")
  }
}
