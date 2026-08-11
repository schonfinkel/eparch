//// Checking a specification, and projecting it onto each participant.
////
//// This is the step that makes repetition possible. Walking a specification
//// assigns a state to each distinct continuation, and `Loop` binds its name to
//// the state at its head, so `Continue` resolves to that state rather than
//// expanding into it. What comes out is a finite graph with cycles in it.
//// Nothing self-referential is produced, so nothing the Gleam compiler rejects
//// as a type cycle is produced either.
////
//// Projection happens here too. A `Message` is a send for its sender, a
//// receive for its recipient, and nothing at all for anybody else. A `Choice`
//// is an internal choice for the participant making it, an external choice for
//// the one being told, and for everybody else an obligation to behave the same
//// way whichever arm was taken, since they are never told which.
////
//// ## Merging
////
//// That last case is the one worth understanding, because it is where a
//// specification gets rejected for a reason that is not a typo.
////
//// ```gleam
//// spec.Choice(at: "Client", to: "Server", branches: [
////   spec.Branch("buy", "Item", spec.Message("Server", "Bank", "charge", "Money", spec.End)),
////   spec.Branch("browse", "Nil", spec.Message("Bank", "Server", "rate", "Money", spec.End)),
//// ])
//// ```
////
//// The bank is told nothing about the client's decision, yet it has to send in
//// one arm and receive in the other. There is no single thing the bank can do
//// that is right either way, so this is rejected as `Unmergeable`. The fix is
//// always the same: tell the bank, by routing the decision through it.
////
//// Views that differ only in what they are *willing to receive* do merge,
//// because a participant offering more arms than it needs is not wrong. That
//// is the standard full merge, and it is what makes most real protocols
//// project at all.
////
//// ## What is checked
////
//// Everything in `Error`, but the ones that catch real mistakes are
//// `Unmergeable` above, `UnguardedRecursion` for a loop that spins without
//// anybody speaking, `IdleLoop` for a loop one participant sits out entirely
//// and therefore cannot tell has gone round again, and `UnmetRequirement` for
//// a contact point that demands a guarantee nothing established.
////

import eparch/protocol/spec.{type Branch, type Protocol, type Spec}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/set
import gleam/string

/// One participant's view of a protocol, flattened.
///
pub type Graph {
  Graph(role: String, initial: String, states: List(State))
}

/// A named position, and the one thing this participant does there.
///
pub type State {
  State(name: String, action: Action)
}

/// What a participant does at a state.
///
pub type Action {
  /// Transmit to `to`, then move on.
  Sends(to: String, label: String, payload: String, next: String)
  /// Accept from `from`, then move on.
  Receives(from: String, label: String, payload: String, next: String)
  /// Pick one arm and tell `to` which.
  Selects(to: String, arms: List(Arm))
  /// `from` picks, so every arm has to be handled.
  Offers(from: String, arms: List(Arm))
  /// Nothing is owed in any direction.
  Done
}

/// One arm of a choice, as seen by one participant.
///
pub type Arm {
  Arm(label: String, payload: String, next: String)
}

/// Everything that stops a specification becoming a graph.
///
pub type Error {
  /// Fewer than two participants is not a protocol.
  TooFewRoles(count: Int)
  /// The same participant is named twice in `roles`.
  DuplicateRole(role: String)
  /// A message or choice named a participant the protocol does not have.
  UnknownRole(role: String, at: String)
  /// A message was addressed from a participant to itself.
  SelfAddressed(role: String, label: String)
  /// A choice with fewer than two arms is not a choice.
  DegenerateChoice(at: String, arms: Int)
  /// Two arms of one choice share a label, so the participant being told
  /// cannot work out which was taken.
  AmbiguousArms(at: String, label: String)
  /// `Continue` named a loop that is not in scope.
  UnboundContinue(name: String)
  /// A loop nested inside a loop of the same name. Legal in principle,
  /// confusing in generated code, and never what was meant.
  ShadowedLoop(name: String)
  /// A loop whose body can return to its head without anybody communicating,
  /// which is a spin rather than a protocol.
  UnguardedRecursion(name: String)
  /// A loop one participant can sit out entirely, so it has no way of knowing
  /// the protocol has gone round again.
  IdleLoop(role: String, name: String)
  /// A participant's view of a choice it is not told about differs between
  /// arms, so there is nothing it can do that is right either way.
  Unmergeable(role: String, states: List(String))
  /// Two different states were given the same name.
  DuplicateStateName(name: String)
  /// A participant that never communicates.
  Uninvolved(role: String)
  /// `Require` or `Consume` demanded a guarantee that nothing established, or
  /// that an earlier `Consume` already spent.
  UnmetRequirement(name: String)
  /// The same guarantee asserted twice with the first still live.
  DuplicateAssertion(name: String)
  /// A loop that ends holding different guarantees than it began with, so the
  /// second time round is not the same protocol as the first.
  UnbalancedLoop(name: String, differing: List(String))
}

/// Check a protocol, then project it onto every participant.
///
/// ## Example
///
/// ```gleam
/// let assert Ok([customer, teller]) = graph.compile(atm())
/// ```
///
pub fn compile(protocol: Protocol) -> Result(List(Graph), Error) {
  use _ <- result.try(validate(protocol))
  list.try_map(protocol.roles, project(protocol, _))
}

/// Project a protocol onto one participant.
///
/// Assumes the protocol is well formed, which `compile` checks first. Calling
/// this directly on an unchecked protocol will report projection errors rather
/// than the specification error that caused them.
///
pub fn project(protocol: Protocol, role: String) -> Result(Graph, Error) {
  use _ <- result.try(participates(protocol.spec, role))

  let empty =
    Builder(
      states: dict.new(),
      used: [],
      order: 0,
      merged: dict.new(),
      aliases: dict.new(),
    )

  use #(initial, builder) <- result.try(walk(
    protocol.spec,
    role,
    dict.new(),
    named(protocol.initial),
    empty,
  ))

  assemble(role, initial, builder)
}

// PROJECTION

type Builder {
  Builder(
    states: Dict(String, #(Int, State)),
    /// Names already claimed, so a generated one never collides.
    used: List(String),
    order: Int,
    /// Merges already performed, keyed on the set of states being merged.
    /// Consulted before merging, which is what makes merging terminate on a
    /// protocol that loops.
    merged: Dict(String, String),
    /// Names that were asked for but never claimed, pointing at the name used
    /// instead. Resolved once at the end.
    aliases: Dict(String, String),
  )
}

/// What to call the state about to be created.
type Want {
  Named(String)
  Anonymous
}

/// Ask for a name, in the form the emitter can use.
fn named(name: String) -> Want {
  Named(pascal(name))
}

/// Sorts terminal states last, wherever in the protocol they were reached.
const terminal_order = 1_000_000

fn walk(
  node: Spec,
  role: String,
  loops: Dict(String, String),
  want: Want,
  builder: Builder,
) -> Result(#(String, Builder), Error) {
  use #(name, builder) <- result.try(step(node, role, loops, want, builder))

  // A step does not always get to use the name it was asked for: `Continue`
  // resolves to a state that already exists, and a merge may collapse onto
  // one. Recording the redirection here, once, is what keeps every one of
  // those cases from leaving a dangling reference behind.
  case want {
    Named(given) if given != name ->
      case list.contains(builder.used, given) {
        True -> Ok(#(name, builder))
        False ->
          Ok(#(
            name,
            Builder(
              ..builder,
              aliases: dict.insert(builder.aliases, given, name),
            ),
          ))
      }
    _ -> Ok(#(name, builder))
  }
}

fn step(
  node: Spec,
  role: String,
  loops: Dict(String, String),
  want: Want,
  builder: Builder,
) -> Result(#(String, Builder), Error) {
  case node {
    // Resolves to a state that already exists, so nothing new is created.
    // This is the cycle.
    spec.Continue(name) ->
      case dict.get(loops, name) {
        Ok(target) -> Ok(#(target, builder))
        Error(Nil) -> Error(UnboundContinue(name))
      }

    // A loop's head is whatever state its body starts in, so the name is bound
    // before the body is walked.
    spec.Loop(name:, body:) ->
      walk(
        body,
        role,
        dict.insert(loops, name, pascal(name)),
        named(name),
        builder,
      )

    spec.At(name:, then:) -> walk(then, role, loops, named(name), builder)

    // Contact points describe no communication, so they are transparent to
    // projection. `assertions` has already checked them.
    spec.Assert(name: _, then:) -> walk(then, role, loops, want, builder)
    spec.Require(name: _, then:) -> walk(then, role, loops, want, builder)
    spec.Consume(name: _, then:) -> walk(then, role, loops, want, builder)

    // Every unnamed `End` gets the same name, so they collapse into one
    // terminal state rather than leaving a dead marker per branch.
    spec.End -> {
      let name = case want {
        Named(given) -> given
        Anonymous -> "Ended"
      }
      use builder <- result.try(emit(
        builder,
        terminal_order,
        State(name:, action: Done),
      ))
      Ok(#(name, builder))
    }

    spec.Message(from:, to:, label:, payload:, then:) ->
      case from == role, to == role {
        // Somebody else's message. Skip it and keep the name we were asked
        // for, so the state after it takes the name of the state before.
        False, False -> walk(then, role, loops, want, builder)

        _, _ -> {
          let #(name, order, builder) =
            reserve(want, "At" <> pascal(label), builder)
          use #(next, builder) <- result.try(walk(
            then,
            role,
            loops,
            Anonymous,
            builder,
          ))
          let action = case from == role {
            True -> Sends(to:, label:, payload:, next:)
            False -> Receives(from:, label:, payload:, next:)
          }
          use builder <- result.try(emit(builder, order, State(name:, action:)))
          Ok(#(name, builder))
        }
      }

    spec.Choice(at:, to:, branches:) ->
      case at == role, to == role {
        // Not told, so this participant has to behave the same way whichever
        // arm was taken. Merging is what checks that it can.
        False, False -> {
          use #(names, builder) <- result.try(
            walk_uninvolved(branches, role, loops, builder, []),
          )
          merge(names, role, loops, want, builder)
        }

        _, _ -> {
          let #(name, order, builder) = reserve(want, "Decision", builder)
          use #(arms, builder) <- result.try(
            walk_arms(branches, role, loops, builder, []),
          )
          let action = case at == role {
            True -> Selects(to:, arms:)
            False -> Offers(from: at, arms:)
          }
          use builder <- result.try(emit(builder, order, State(name:, action:)))
          Ok(#(name, builder))
        }
      }
  }
}

fn walk_arms(
  branches: List(Branch),
  role: String,
  loops: Dict(String, String),
  builder: Builder,
  acc: List(Arm),
) -> Result(#(List(Arm), Builder), Error) {
  case branches {
    [] -> Ok(#(list.reverse(acc), builder))
    [spec.Branch(label:, payload:, then:), ..rest] -> {
      use #(next, builder) <- result.try(walk(
        then,
        role,
        loops,
        Anonymous,
        builder,
      ))
      walk_arms(rest, role, loops, builder, [
        Arm(label:, payload:, next:),
        ..acc
      ])
    }
  }
}

fn walk_uninvolved(
  branches: List(Branch),
  role: String,
  loops: Dict(String, String),
  builder: Builder,
  acc: List(String),
) -> Result(#(List(String), Builder), Error) {
  case branches {
    [] -> Ok(#(list.reverse(acc), builder))
    [branch, ..rest] -> {
      use #(name, builder) <- result.try(walk(
        branch.then,
        role,
        loops,
        Anonymous,
        builder,
      ))
      walk_uninvolved(rest, role, loops, builder, [name, ..acc])
    }
  }
}

// MERGING

/// Collapse several views of the same point into the one thing a participant
/// that is not told which arm was taken can do.
fn merge(
  names: List(String),
  role: String,
  loops: Dict(String, String),
  want: Want,
  builder: Builder,
) -> Result(#(String, Builder), Error) {
  case list.unique(names) {
    [] -> Error(Unmergeable(role:, states: names))
    [only] -> Ok(#(only, builder))
    distinct -> {
      let key = string.join(list.sort(distinct, string.compare), "|")

      // Already merged, possibly by an outer call still in progress. Returning
      // the reserved name rather than merging again is what makes this
      // terminate on a protocol that loops: the fixpoint is reached by tying
      // the knot instead of by unfolding.
      case dict.get(builder.merged, key) {
        Ok(existing) -> Ok(#(existing, builder))
        Error(Nil) -> {
          let #(name, order, builder) = reserve(want, "Merged", builder)
          let builder =
            Builder(..builder, merged: dict.insert(builder.merged, key, name))

          use actions <- result.try(
            list.try_map(distinct, fn(each) {
              case dict.get(builder.states, each) {
                Ok(#(_, state)) -> Ok(state.action)
                Error(Nil) -> Error(Unmergeable(role:, states: distinct))
              }
            }),
          )

          use #(action, builder) <- result.try(merge_actions(
            actions,
            role,
            loops,
            distinct,
            builder,
          ))
          use builder <- result.try(emit(builder, order, State(name:, action:)))
          Ok(#(name, builder))
        }
      }
    }
  }
}

fn merge_actions(
  actions: List(Action),
  role: String,
  loops: Dict(String, String),
  origin: List(String),
  builder: Builder,
) -> Result(#(Action, Builder), Error) {
  let refusal = Unmergeable(role:, states: origin)

  case actions {
    [] -> Error(refusal)

    [Done, ..rest] ->
      case list.all(rest, fn(action) { action == Done }) {
        True -> Ok(#(Done, builder))
        False -> Error(refusal)
      }

    // Identical transmissions merge, because there is one thing to do and
    // every arm agrees on it. Transmissions that differ do not: the
    // participant would have to know which arm was taken to know what to send,
    // and it was not told.
    [Sends(to:, label:, payload:, ..), ..] -> {
      use nexts <- result.try(
        list.try_map(actions, fn(action) {
          case action {
            Sends(to: t, label: l, payload: p, next:)
              if t == to && l == label && p == payload
            -> Ok(next)
            _ -> Error(refusal)
          }
        }),
      )
      use #(next, builder) <- result.try(merge(
        nexts,
        role,
        loops,
        Anonymous,
        builder,
      ))
      Ok(#(Sends(to:, label:, payload:, next:), builder))
    }

    // Internal choices merge only when the arms on offer are the same in
    // every view. Widening one would be offering the participant a decision it
    // is only sometimes allowed to make.
    [Selects(to:, arms:), ..] -> {
      use groups <- result.try(
        list.try_map(actions, fn(action) {
          case action {
            Selects(to: t, arms: other) if t == to ->
              case labels(other) == labels(arms) {
                True -> Ok(other)
                False -> Error(refusal)
              }
            _ -> Error(refusal)
          }
        }),
      )
      use #(arms, builder) <- result.try(
        merge_shared(arms, groups, role, loops, origin, builder, []),
      )
      Ok(#(Selects(to:, arms:), builder))
    }

    // Everything left is receive-like: a plain receive, an external choice, or
    // a mixture of the two. They merge into the union of their arms, because
    // being ready for an arm this particular path will never take costs
    // nothing.
    //
    // This is the case that makes a three-party protocol project at all. A
    // participant that is not told which way a decision went does not need to
    // be told: it only has to be ready for either of the messages that might
    // follow from it, which is exactly one external choice over both.
    [first, ..] -> {
      use from <- result.try(case first {
        Receives(from:, ..) -> Ok(from)
        Offers(from:, ..) -> Ok(from)
        _ -> Error(refusal)
      })

      use views <- result.try(
        list.try_map(actions, fn(action) {
          case action {
            Receives(from: sender, label:, payload:, next:) if sender == from ->
              Ok(#(True, [Arm(label:, payload:, next:)]))
            Offers(from: sender, arms:) if sender == from -> Ok(#(False, arms))
            _ -> Error(refusal)
          }
        }),
      )

      let already_choices = list.all(views, fn(view) { !view.0 })
      let groups = list.map(views, fn(view) { view.1 })
      let every =
        groups
        |> list.flatten
        |> list.map(fn(arm) { arm.label })
        |> list.unique

      use #(arms, builder) <- result.try(
        merge_union(every, groups, role, loops, origin, builder, []),
      )

      case arms, already_choices {
        // Every view awaited the same single message, so it stays a plain
        // receive rather than becoming a choice with nothing to choose.
        [Arm(label:, payload:, next:)], False ->
          Ok(#(Receives(from:, label:, payload:, next:), builder))
        _, _ -> Ok(#(Offers(from:, arms:), builder))
      }
    }
  }
}

/// Merge arms that every view agrees on, arm by arm.
fn merge_shared(
  arms: List(Arm),
  groups: List(List(Arm)),
  role: String,
  loops: Dict(String, String),
  origin: List(String),
  builder: Builder,
  acc: List(Arm),
) -> Result(#(List(Arm), Builder), Error) {
  case arms {
    [] -> Ok(#(list.reverse(acc), builder))
    [arm, ..rest] -> {
      use matching <- result.try(
        list.try_map(groups, fn(group) {
          case list.find(group, fn(other) { other.label == arm.label }) {
            Ok(found) if found.payload == arm.payload -> Ok(found.next)
            _ -> Error(Unmergeable(role:, states: origin))
          }
        }),
      )
      use #(next, builder) <- result.try(merge(
        matching,
        role,
        loops,
        Anonymous,
        builder,
      ))
      merge_shared(rest, groups, role, loops, origin, builder, [
        Arm(label: arm.label, payload: arm.payload, next:),
        ..acc
      ])
    }
  }
}

/// Merge arms by label across views, keeping arms that only some views carry.
fn merge_union(
  labels: List(String),
  groups: List(List(Arm)),
  role: String,
  loops: Dict(String, String),
  origin: List(String),
  builder: Builder,
  acc: List(Arm),
) -> Result(#(List(Arm), Builder), Error) {
  case labels {
    [] -> Ok(#(list.reverse(acc), builder))
    [label, ..rest] -> {
      let present =
        list.filter_map(groups, fn(group) {
          list.find(group, fn(arm) { arm.label == label })
        })

      use payload <- result.try(agreed_payload(present, role, origin))
      use #(next, builder) <- result.try(merge(
        list.map(present, fn(arm) { arm.next }),
        role,
        loops,
        Anonymous,
        builder,
      ))
      merge_union(rest, groups, role, loops, origin, builder, [
        Arm(label:, payload:, next:),
        ..acc
      ])
    }
  }
}

fn agreed_payload(
  arms: List(Arm),
  role: String,
  origin: List(String),
) -> Result(String, Error) {
  case arms {
    [first, ..rest] ->
      case list.all(rest, fn(arm) { arm.payload == first.payload }) {
        True -> Ok(first.payload)
        False -> Error(Unmergeable(role:, states: origin))
      }
    [] -> Error(Unmergeable(role:, states: origin))
  }
}

fn labels(arms: List(Arm)) -> List(String) {
  arms |> list.map(fn(arm) { arm.label }) |> list.sort(string.compare)
}

// BUILDING

/// Claim a name and a position for the state about to be built.
///
/// Both are decided before the continuation is walked, which is what lets a
/// `Loop` bind its head, and what puts the emitted states in the order a
/// reader meets them rather than the order they finish in.
fn reserve(
  want: Want,
  base: String,
  builder: Builder,
) -> #(String, Int, Builder) {
  let name = case want {
    Named(given) -> given
    Anonymous -> unique(base, builder.used, 1)
  }
  #(
    name,
    builder.order,
    Builder(..builder, used: [name, ..builder.used], order: builder.order + 1),
  )
}

fn unique(base: String, used: List(String), attempt: Int) -> String {
  let candidate = case attempt {
    1 -> base
    n -> base <> int.to_string(n)
  }
  case list.contains(used, candidate) {
    False -> candidate
    True -> unique(base, used, attempt + 1)
  }
}

fn emit(builder: Builder, order: Int, state: State) -> Result(Builder, Error) {
  case dict.get(builder.states, state.name) {
    // Every `End` produces the same terminal state, so arriving at a name
    // already held by an identical state is the expected case, not a clash.
    Ok(#(_, existing)) if existing == state -> Ok(builder)
    Ok(#(_, _)) -> Error(DuplicateStateName(state.name))
    Error(Nil) ->
      Ok(
        Builder(
          ..builder,
          states: dict.insert(builder.states, state.name, #(order, state)),
        ),
      )
  }
}

/// Resolve redirections, drop what became unreachable, order what is left,
/// and check that nothing dangles.
fn assemble(
  role: String,
  initial: String,
  builder: Builder,
) -> Result(Graph, Error) {
  let resolve = fn(name) { follow(builder.aliases, name, []) }

  let ordered =
    builder.states
    |> dict.values
    |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
    |> list.map(fn(entry) { redirect({ entry.1 }, resolve) })

  let known = ordered |> list.map(fn(state) { state.name }) |> set.from_list
  let initial = resolve(initial)

  use _ <- result.try(
    [initial, ..list.flatten(list.map(ordered, successors))]
    |> list.try_each(fn(name) {
      case set.contains(known, name) {
        True -> Ok(Nil)
        False -> Error(IdleLoop(role:, name:))
      }
    }),
  )

  // Merging supersedes the per-arm states it was built from, so a projection
  // can hold states nothing points at any more. They would emit as markers no
  // function can reach, which is at best confusing, so they go.
  let live = reachable(ordered, [initial], set.new())
  let states =
    list.filter(ordered, fn(state) { set.contains(live, state.name) })

  // A projection made entirely of terminal states is a participant that never
  // says anything, which is a mistake in the role list rather than a protocol.
  case list.all(states, fn(state) { state.action == Done }) {
    True -> Error(Uninvolved(role))
    False -> Ok(Graph(role:, initial:, states:))
  }
}

fn reachable(
  states: List(State),
  frontier: List(String),
  seen: set.Set(String),
) -> set.Set(String) {
  case frontier {
    [] -> seen
    [name, ..rest] ->
      case set.contains(seen, name) {
        True -> reachable(states, rest, seen)
        False -> {
          let next = case list.find(states, fn(state) { state.name == name }) {
            Ok(state) -> successors(state)
            Error(Nil) -> []
          }
          reachable(states, list.append(next, rest), set.insert(seen, name))
        }
      }
  }
}

fn follow(
  aliases: Dict(String, String),
  name: String,
  seen: List(String),
) -> String {
  case list.contains(seen, name) {
    True -> name
    False ->
      case dict.get(aliases, name) {
        Ok(target) -> follow(aliases, target, [name, ..seen])
        Error(Nil) -> name
      }
  }
}

fn redirect(state: State, resolve: fn(String) -> String) -> State {
  let action = case state.action {
    Sends(to:, label:, payload:, next:) ->
      Sends(to:, label:, payload:, next: resolve(next))
    Receives(from:, label:, payload:, next:) ->
      Receives(from:, label:, payload:, next: resolve(next))
    Selects(to:, arms:) -> Selects(to:, arms: redirect_arms(arms, resolve))
    Offers(from:, arms:) -> Offers(from:, arms: redirect_arms(arms, resolve))
    Done -> Done
  }
  State(..state, action:)
}

fn redirect_arms(arms: List(Arm), resolve: fn(String) -> String) -> List(Arm) {
  list.map(arms, fn(arm) { Arm(..arm, next: resolve(arm.next)) })
}

/// The states reachable in one step. Useful for traversal, and for checking
/// that a graph refers only to states it has.
///
pub fn successors(state: State) -> List(String) {
  case state.action {
    Sends(next:, ..) -> [next]
    Receives(next:, ..) -> [next]
    Selects(arms:, ..) -> list.map(arms, fn(arm) { arm.next })
    Offers(arms:, ..) -> list.map(arms, fn(arm) { arm.next })
    Done -> []
  }
}

/// Look a state up by name.
///
pub fn state(graph: Graph, name: String) -> Result(State, Nil) {
  list.find(graph.states, fn(state) { state.name == name })
}

/// The states of a graph, in declaration order. Useful for tests.
///
pub fn state_names(graph: Graph) -> List(String) {
  list.map(graph.states, fn(state) { state.name })
}

/// `card` becomes `Card`, `new_balance` becomes `NewBalance`.
///
/// Every state name goes through this, so a graph only ever holds names the
/// emitter can use as Gleam type names. Deliberately gentler than
/// `string.capitalise`, which lowercases the rest and would turn a name the
/// author already wrote as `AtBalance` into `Atbalance`.
fn pascal(name: String) -> String {
  name
  |> string.split("_")
  |> list.map(fn(part) {
    case string.pop_grapheme(part) {
      Ok(#(first, rest)) -> string.uppercase(first) <> rest
      Error(Nil) -> part
    }
  })
  |> string.concat
}

// VALIDATION
//
// Checked once against the specification, independently of which participant
// it is about to be projected onto.

fn validate(protocol: Protocol) -> Result(Nil, Error) {
  use _ <- result.try(case protocol.roles {
    [_, _, ..] -> Ok(Nil)
    other -> Error(TooFewRoles(list.length(other)))
  })
  use _ <- result.try(distinct_roles(protocol.roles, []))
  use _ <- result.try(check(protocol.spec, protocol.roles, []))
  assertions(protocol.spec, [], dict.new())
}

fn distinct_roles(roles: List(String), seen: List(String)) -> Result(Nil, Error) {
  case roles {
    [] -> Ok(Nil)
    [role, ..rest] ->
      case list.contains(seen, role) {
        True -> Error(DuplicateRole(role))
        False -> distinct_roles(rest, [role, ..seen])
      }
  }
}

fn check(
  node: Spec,
  roles: List(String),
  bound: List(String),
) -> Result(Nil, Error) {
  case node {
    spec.End -> Ok(Nil)

    spec.Continue(name) ->
      case list.contains(bound, name) {
        True -> Ok(Nil)
        False -> Error(UnboundContinue(name))
      }

    spec.At(name: _, then:) -> check(then, roles, bound)
    spec.Assert(name: _, then:) -> check(then, roles, bound)
    spec.Require(name: _, then:) -> check(then, roles, bound)
    spec.Consume(name: _, then:) -> check(then, roles, bound)

    spec.Loop(name:, body:) -> {
      use _ <- result.try(case list.contains(bound, name) {
        True -> Error(ShadowedLoop(name))
        False -> Ok(Nil)
      })
      use _ <- result.try(case unguarded(body, name) {
        True -> Error(UnguardedRecursion(name))
        False -> Ok(Nil)
      })
      check(body, roles, [name, ..bound])
    }

    spec.Message(from:, to:, label:, payload: _, then:) -> {
      use _ <- result.try(known(from, roles, label))
      use _ <- result.try(known(to, roles, label))
      use _ <- result.try(case from == to {
        True -> Error(SelfAddressed(from, label))
        False -> Ok(Nil)
      })
      check(then, roles, bound)
    }

    spec.Choice(at:, to:, branches:) -> {
      use _ <- result.try(known(at, roles, "choice"))
      use _ <- result.try(known(to, roles, "choice"))
      use _ <- result.try(case at == to {
        True -> Error(SelfAddressed(at, "choice"))
        False -> Ok(Nil)
      })
      use _ <- result.try(case list.length(branches) {
        n if n < 2 -> Error(DegenerateChoice(at, n))
        _ -> Ok(Nil)
      })
      use _ <- result.try(distinct_arms(at, branches, []))
      list.try_each(branches, fn(branch) { check(branch.then, roles, bound) })
    }
  }
}

fn known(role: String, roles: List(String), at: String) -> Result(Nil, Error) {
  case list.contains(roles, role) {
    True -> Ok(Nil)
    False -> Error(UnknownRole(role:, at:))
  }
}

fn distinct_arms(
  at: String,
  branches: List(Branch),
  seen: List(String),
) -> Result(Nil, Error) {
  case branches {
    [] -> Ok(Nil)
    [branch, ..rest] ->
      case list.contains(seen, branch.label) {
        True -> Error(AmbiguousArms(at, branch.label))
        False -> distinct_arms(at, rest, [branch.label, ..seen])
      }
  }
}

/// Can this loop return to its own head without anybody saying anything?
///
/// A `Message` guards it. So does a `Choice`, because taking an arm means
/// telling somebody which arm was taken.
fn unguarded(node: Spec, name: String) -> Bool {
  case node {
    spec.Continue(n) -> n == name
    spec.At(name: _, then:) -> unguarded(then, name)
    spec.Assert(name: _, then:) -> unguarded(then, name)
    spec.Require(name: _, then:) -> unguarded(then, name)
    spec.Consume(name: _, then:) -> unguarded(then, name)
    // A nested loop of the same name rebinds it, so any `Continue` inside
    // belongs to the inner one.
    spec.Loop(name: n, body:) -> n != name && unguarded(body, name)
    spec.Message(..) -> False
    spec.Choice(..) -> False
    spec.End -> False
  }
}

/// Can this loop return to its head without *this participant* saying
/// anything?
///
/// Weaker than `unguarded` and checked per participant, because a loop that
/// somebody sits out is one they cannot tell has gone round again. Their
/// projection would have no state to come back to, so it is rejected here with
/// a reason rather than later as a dangling edge.
fn participates(node: Spec, role: String) -> Result(Nil, Error) {
  case node {
    spec.End -> Ok(Nil)
    spec.Continue(_) -> Ok(Nil)
    spec.At(name: _, then:) -> participates(then, role)
    spec.Assert(name: _, then:) -> participates(then, role)
    spec.Require(name: _, then:) -> participates(then, role)
    spec.Consume(name: _, then:) -> participates(then, role)
    spec.Message(then:, ..) -> participates(then, role)
    spec.Choice(branches:, ..) ->
      list.try_each(branches, fn(branch) { participates(branch.then, role) })
    spec.Loop(name:, body:) ->
      case idle(body, name, role) {
        True -> Error(IdleLoop(role:, name:))
        False -> participates(body, role)
      }
  }
}

fn idle(node: Spec, name: String, role: String) -> Bool {
  case node {
    spec.Continue(n) -> n == name
    spec.At(name: _, then:) -> idle(then, name, role)
    spec.Assert(name: _, then:) -> idle(then, name, role)
    spec.Require(name: _, then:) -> idle(then, name, role)
    spec.Consume(name: _, then:) -> idle(then, name, role)
    spec.Loop(name: n, body:) -> n != name && idle(body, name, role)
    spec.End -> False
    spec.Message(from:, to:, then:, ..) ->
      case from == role || to == role {
        True -> False
        False -> idle(then, name, role)
      }
    spec.Choice(at:, to:, branches:) ->
      case at == role || to == role {
        True -> False
        False ->
          list.any(branches, fn(branch) { idle(branch.then, name, role) })
      }
  }
}

// CONTACT POINTS
//
// Guarantees flow downward and never sideways, so each arm of a choice is
// checked against the environment at the choice, and nothing an arm asserts
// escapes it. A loop has to end holding what it began with, because the second
// time round starts where the first one did.

fn assertions(
  node: Spec,
  live: List(String),
  loops: Dict(String, List(String)),
) -> Result(Nil, Error) {
  case node {
    spec.End -> Ok(Nil)

    spec.Continue(name) ->
      case dict.get(loops, name) {
        // A `Continue` naming a loop bound outside whatever is being checked.
        // Not an error here: `check` has already rejected genuinely unbound
        // ones, and `well_asserted` is deliberately usable on a fragment,
        // which cannot see its own context.
        Error(Nil) -> Ok(Nil)
        Ok(entry) -> {
          let differing =
            set.symmetric_difference(set.from_list(entry), set.from_list(live))
          case set.is_empty(differing) {
            True -> Ok(Nil)
            False ->
              Error(UnbalancedLoop(
                name:,
                differing: set.to_list(differing) |> list.sort(string.compare),
              ))
          }
        }
      }

    spec.Loop(name:, body:) ->
      assertions(body, live, dict.insert(loops, name, live))

    spec.At(name: _, then:) -> assertions(then, live, loops)

    spec.Assert(name:, then:) ->
      case list.contains(live, name) {
        True -> Error(DuplicateAssertion(name))
        False -> assertions(then, [name, ..live], loops)
      }

    spec.Require(name:, then:) ->
      case list.contains(live, name) {
        True -> assertions(then, live, loops)
        False -> Error(UnmetRequirement(name))
      }

    spec.Consume(name:, then:) ->
      case list.contains(live, name) {
        True ->
          assertions(then, list.filter(live, fn(held) { held != name }), loops)
        False -> Error(UnmetRequirement(name))
      }

    spec.Message(then:, ..) -> assertions(then, live, loops)

    spec.Choice(branches:, ..) ->
      list.try_each(branches, fn(branch) {
        assertions(branch.then, live, loops)
      })
  }
}

/// Are this fragment's contact points consistent with the guarantees already in
/// scope?
///
/// The same check `compile` runs, exposed for a fragment rather than a whole
/// protocol, because interleaving composition has to ask it repeatedly about
/// pieces it is part way through assembling.
///
/// ## Example
///
/// ```gleam
/// // A payment that needs a code somebody else has to have issued.
/// let fragment = spec.Consume("tan", spec.Message("A", "B", "pay", "Money", spec.End))
///
/// assert graph.well_asserted(fragment, given: []) == False
/// assert graph.well_asserted(fragment, given: ["tan"]) == True
/// ```
///
pub fn well_asserted(node: Spec, given given: List(String)) -> Bool {
  case assertions(node, given, dict.new()) {
    Ok(Nil) -> True
    Error(_) -> False
  }
}

/// Render an error as a line suitable for a terminal.
///
pub fn describe(error: Error) -> String {
  case error {
    TooFewRoles(count:) ->
      "a protocol needs at least two participants, and this one has "
      <> int.to_string(count)
    DuplicateRole(role:) -> "`" <> role <> "` is named twice as a participant"
    UnknownRole(role:, at:) ->
      "`" <> role <> "` is not a participant in this protocol (at " <> at <> ")"
    SelfAddressed(role:, label:) ->
      "`" <> label <> "` is addressed from " <> role <> " to itself"
    DegenerateChoice(at:, arms:) ->
      "a choice at "
      <> at
      <> " has "
      <> int.to_string(arms)
      <> " arms; it needs at least two"
    AmbiguousArms(at:, label:) ->
      "two arms of the choice at "
      <> at
      <> " are both labelled `"
      <> label
      <> "`, so the participant being told cannot tell them apart"
    UnboundContinue(name:) -> "`continue " <> name <> "` has no matching loop"
    ShadowedLoop(name:) ->
      "loop `" <> name <> "` is nested inside a loop of the same name"
    UnguardedRecursion(name:) ->
      "loop `"
      <> name
      <> "` can return to its head without anybody communicating"
    IdleLoop(role:, name:) ->
      "`"
      <> role
      <> "` sits out loop `"
      <> name
      <> "`, so it has no way of knowing the protocol went round again"
    Unmergeable(role:, states:) ->
      "`"
      <> role
      <> "` is not told which arm of a choice was taken, but would have to "
      <> "behave differently depending on it ("
      <> string.join(states, ", ")
      <> "); route the decision through it"
    DuplicateStateName(name:) ->
      "the name `" <> name <> "` was given to two different states"
    Uninvolved(role:) -> "`" <> role <> "` never communicates"
    UnmetRequirement(name:) ->
      "`" <> name <> "` is required here but nothing established it"
    DuplicateAssertion(name:) ->
      "`" <> name <> "` is asserted while an earlier assertion of it is live"
    UnbalancedLoop(name:, differing:) ->
      "loop `"
      <> name
      <> "` ends holding different guarantees than it began with ("
      <> string.join(differing, ", ")
      <> ")"
  }
}
