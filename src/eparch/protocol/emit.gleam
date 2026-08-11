////
//// Writing a projected protocol out as Gleam source.
////
//// `eparch/protocol/graph` turns a specification into one flattened state
//// graph per participant. This turns a graph into a module a project can
//// compile, which is the step that connects the specification layer to
//// `eparch/session/core` and `eparch/protocol_machine`.
////
//// ## Why there is a generator at all
////
//// A two-party protocol that runs once can be written by hand as a nested
//// type, and `session/core`'s markers are built for exactly that. A protocol
//// that repeats cannot: expressing it needs an alias defined in terms of
//// itself, and Gleam rejects that outright. So a repeating protocol has to
//// become a set of named positions with edges between them, and there is no
//// way to write those names down that also tells the compiler what each name
//// stands for.
////
//// A generated module says it instead. Each position becomes an uninhabited
//// type, and each position gets one function unfolding it into the
//// `session/core` shape the protocol says it has:
////
//// ```gleam
//// pub type AtWaiting
//// pub type AtServing
////
//// pub fn at_waiting(
////   channel: Channel(AtWaiting, msg),
//// ) -> Channel(core.Recv(String, AtServing), msg) {
////   core.unchecked_position(channel)
//// }
//// ```
////
//// Unfolding is one level deep, and the continuation is the next flat name, so
//// the cycle that defeats the alias never forms. Everything downstream is
//// ordinary: `core.receive` on the unfolded channel hands back a
//// `Channel(AtServing, msg)`, and `protocol_machine.accept` takes it just as
//// happily, because what it wants is a `Recv` and that is what unfolding
//// produced.
////
//// ## What it costs
////
//// `core.unchecked_position` is a hole, and this is the module that needs it.
//// Its own documentation says what the hole is worth; the part that belongs
//// here is that a generated module is the whole reason it is public, and that
//// nothing at the type level distinguishes a generated call from a
//// hand-written one. What makes the generated ones sound is that the shape was
//// read off a graph `graph.compile` had already checked, and that check is
//// where the guarantee actually lives.
////
//// Positions are uninhabited and their unfolding functions are the only way
//// past them, so a channel at a generated position still cannot go anywhere
//// the protocol does not allow. The hole is one function, in one place, and
//// the rest of the surface is as tight as the hand-written one.
////
//// ## Checking rather than writing
////
//// `review` compares what the emitter would write against what is on disk,
//// which is the shape a CI step wants: regenerate, and fail if the result
//// differs from what was committed. It compares content and not layout, so
//// running `gleam format` over generated files does not make them stale.
////
//// ## Limits
////
//// The emitted module contains positions and their unfoldings, and nothing
//// else. It does not pick a `gen_statem` tag for each position, because how
//// coarse those should be is a decision about the machine rather than about
//// the protocol, and it does not name the wire type, because this layer never
//// sees one. Payload types are the strings the specification carried, resolved
//// by the specification's `imports` lines.
////

import eparch/protocol/graph.{type Arm, type Graph, type State}
import eparch/protocol/spec.{type Protocol}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

// WHAT COMES OUT

/// One generated module.
///
/// `name` is the Gleam module path, so `atm/customer` is what an importing
/// module writes and what `path` turns into a file name. Which source root it
/// sits under is deliberately not decided here: `src/` is the answer for a
/// protocol a project ships, and the wrong one for a protocol only its tests
/// use.
///
pub type Module {
  Module(name: String, source: String)
}

/// Where a module's file belongs, under a source root.
///
/// ## Example
///
/// ```gleam
/// let assert "src/banking/atm/customer.gleam" = emit.path(customer, in: "src")
/// ```
///
pub fn path(module: Module, in root: String) -> String {
  case root {
    "" -> module.name <> ".gleam"
    _ -> root <> "/" <> module.name <> ".gleam"
  }
}

/// Write every participant's module.
///
/// `prefix` is a module path the generated modules go under, so a `prefix` of
/// `"myapp/protocols"` and a protocol named `atm` produce
/// `myapp/protocols/atm/customer`. Pass `""` to put them at the root.
///
/// The protocol is checked first, so anything `graph.compile` rejects comes
/// back here rather than being written out.
///
/// ## Example
///
/// ```gleam
/// let assert Ok([customer, teller]) = emit.modules(atm(), under: "banking")
/// let assert "banking/atm/customer" = customer.name
/// ```
///
pub fn modules(
  protocol: Protocol,
  under prefix: String,
) -> Result(List(Module), graph.Error) {
  use graphs <- result.try(graph.compile(protocol))
  Ok(list.map(graphs, render(protocol, _, prefix)))
}

/// Write one participant's module.
///
/// Unlike `modules` this projects without validating the whole specification
/// first, matching `graph.project`. Prefer `modules` unless there is a reason
/// to want one participant in isolation.
///
pub fn module(
  protocol: Protocol,
  for role: String,
  under prefix: String,
) -> Result(Module, graph.Error) {
  use projected <- result.try(graph.project(protocol, role))
  Ok(render(protocol, projected, prefix))
}

// CHECKING WHAT IS ALREADY THERE

/// What a file on disk says about a module that should have been generated.
///
pub type Status {
  /// The file is there and says what the emitter would say.
  Current
  /// There is no file for it.
  Absent
  /// The file is there and says something else.
  Different
}

/// One module, and what its file had to say.
///
pub type Review {
  Review(module: Module, status: Status)
}

/// Compare generated modules against what is already on disk.
///
/// `read` is handed a module and returns the contents of its file, or
/// `Error(Nil)` if there is no file. Keeping the reading outside means this
/// stays a pure function, and means the caller decides where generated modules
/// live rather than being told.
///
/// Comparison ignores layout, so a generated file that has been through
/// `gleam format` still counts as `Current`. What it does not ignore is a
/// change in what the module says.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(wanted) = emit.modules(atm(), under: "banking")
///
/// let read = fn(module) {
///   simplifile.read(emit.path(module, in: "src"))
///   |> result.replace_error(Nil)
/// }
///
/// case emit.agreed(emit.review(wanted, against: read)) {
///   True -> Ok(Nil)
///   False -> Error("protocol modules are out of date, regenerate them")
/// }
/// ```
///
pub fn review(
  modules: List(Module),
  against read: fn(Module) -> Result(String, Nil),
) -> List(Review) {
  use module <- list.map(modules)

  let status = case read(module) {
    Error(Nil) -> Absent
    Ok(found) ->
      case settled(found) == settled(module.source) {
        True -> Current
        False -> Different
      }
  }

  Review(module:, status:)
}

/// Whether every reviewed module is current.
///
pub fn agreed(reviews: List(Review)) -> Bool {
  use review <- list.all(reviews)
  review.status == Current
}

/// A reviewed module in one line, for a CI step to print.
///
pub fn describe(review: Review) -> String {
  case review.status {
    Current -> review.module.name <> ": up to date"
    Absent -> review.module.name <> ": missing, has never been generated"
    Different -> review.module.name <> ": out of date, regenerate it"
  }
}

/// Strip everything a formatter is allowed to change.
///
/// Whitespace goes, and so does the trailing comma the formatter adds when it
/// breaks a call across lines. What is left is dense and unreadable, which is
/// fine: nothing reads it, it only gets compared.
fn settled(source: String) -> String {
  source
  |> string.to_graphemes
  |> list.filter(fn(char) {
    char != " " && char != "\n" && char != "\t" && char != "\r"
  })
  |> string.concat
  |> string.replace(",)", ")")
  |> string.replace(",]", "]")
}

// LAYING OUT A MODULE
//
// Names are allocated before anything is rendered, because a helper that walks
// to the third arm of a choice has to name the unfolding function for the tail
// it walks through, and that tail does not exist in the graph.

/// A position in the generated module: an uninhabited type, and the one
/// function that says what it stands for.
type Position {
  Position(marker: String, unfold: String, shape: String, note: List(String))
}

/// A shortcut to one arm of a choice, so nobody has to count `offered_right`s.
type Helper {
  Helper(
    name: String,
    marker: String,
    shape: String,
    steps: List(String),
    note: List(String),
  )
}

type Layout {
  Layout(positions: List(Position), helpers: List(Helper))
}

/// Names already claimed. Types and values do not share a namespace in Gleam,
/// but keeping one list of each is cheaper than being clever about it.
type Taken {
  Taken(types: List(String), values: List(String))
}

/// The differences between a choice this participant makes and one it is told
/// about. Everything else about the two is the same, which is why they are one
/// piece of code and not two.
type Side {
  Side(
    choice: String,
    carries: String,
    left: String,
    right: String,
    lead: String,
    take: String,
  )
}

fn selecting(to: String) -> Side {
  Side(
    choice: "core.Choose",
    carries: "core.Send",
    left: "core.choose_left",
    right: "core.choose_right",
    lead: "Pick one arm and tell `" <> to <> "` which:",
    take: "Take",
  )
}

fn offering(from: String) -> Side {
  Side(
    choice: "core.Offer",
    carries: "core.Recv",
    left: "core.offered_left",
    right: "core.offered_right",
    lead: "`" <> from <> "` picks, so every arm needs a continuation:",
    take: "Follow",
  )
}

fn layout(projected: Graph) -> Layout {
  let claimed =
    Taken(
      types: list.map(projected.states, fn(state) { state.name }),
      values: [],
    )

  let #(positions, helpers, _) =
    list.fold(projected.states, #([], [], claimed), fn(acc, state) {
      let #(positions, helpers, taken) = acc
      let #(added, shortcuts, taken) = plot(state, taken)
      #(list.append(positions, added), list.append(helpers, shortcuts), taken)
    })

  Layout(positions:, helpers:)
}

fn plot(state: State, taken: Taken) -> #(List(Position), List(Helper), Taken) {
  let #(unfold, taken) = claim_value(snake(state.name), taken)

  case state.action {
    graph.Done -> #(
      [
        Position(
          marker: state.name,
          unfold:,
          shape: "core.Done",
          note: wrap(
            "Nothing is owed in either direction. A channel here can be closed"
            <> " with `core.finish`, and nothing else.",
          ),
        ),
      ],
      [],
      taken,
    )

    graph.Sends(to:, label:, payload:, next:) -> #(
      [
        Position(
          marker: state.name,
          unfold:,
          shape: "core.Send(" <> payload <> ", " <> next <> ")",
          note: wrap(
            "Send `"
            <> label
            <> "` to `"
            <> to
            <> "`, carrying `"
            <> payload
            <> "`, then continue at `"
            <> next
            <> "`.",
          ),
        ),
      ],
      [],
      taken,
    )

    graph.Receives(from:, label:, payload:, next:) -> #(
      [
        Position(
          marker: state.name,
          unfold:,
          shape: "core.Recv(" <> payload <> ", " <> next <> ")",
          note: wrap(
            "Accept `"
            <> label
            <> "` from `"
            <> from
            <> "`, carrying `"
            <> payload
            <> "`, then continue at `"
            <> next
            <> "`.",
          ),
        ),
      ],
      [],
      taken,
    )

    graph.Selects(to:, arms:) ->
      choose(state, unfold, arms, selecting(to), taken)

    graph.Offers(from:, arms:) ->
      choose(state, unfold, arms, offering(from), taken)
  }
}

/// Lay out a choice.
///
/// `core` only has binary branching, so a choice of three or more arms nests to
/// the right. The nesting needs a name at every level, and only the outermost
/// one is a state the graph knows about, so the rest are invented here.
fn choose(
  state: State,
  unfold: String,
  arms: List(Arm),
  side: Side,
  taken: Taken,
) -> #(List(Position), List(Helper), Taken) {
  let depth = list.length(arms) - 2
  let #(tails, taken) = claim_tails(state.name, depth, taken, [])

  let markers = [#(state.name, unfold), ..tails]
  let positions = spread(state.name, markers, arms, side)

  let #(helpers, taken) =
    list.map(markers, fn(pair) { pair.1 })
    |> shortcuts(state, arms, side, taken)

  #(positions, helpers, taken)
}

/// One position per level of the nesting, each holding one arm and pointing at
/// the level below.
fn spread(
  origin: String,
  markers: List(#(String, String)),
  arms: List(Arm),
  side: Side,
) -> List(Position) {
  case markers, arms {
    [], _ -> []

    // Three or more arms and a name for what comes after this one, so hold the
    // first here and defer the rest to the level below.
    [#(marker, unfold), #(below, _) as next, ..rest],
      [first, second, third, ..more]
    -> [
      Position(
        marker:,
        unfold:,
        shape: side.choice
          <> "("
          <> carried(first, side)
          <> ", "
          <> below
          <> ")",
        note: annotate(origin, marker, arms, side),
      ),
      ..spread(origin, [next, ..rest], [second, third, ..more], side)
    ]

    // Everything left fits under this one name. Two arms is the bottom of the
    // nesting and the ordinary case; one arm or none is not a choice at all,
    // and `graph.compile` refuses those, so `nested` renders something
    // harmless rather than reaching for a panic nothing can trigger.
    [#(marker, unfold), ..], _ -> [
      Position(
        marker:,
        unfold:,
        shape: nested(arms, side),
        note: annotate(origin, marker, arms, side),
      ),
    ]
  }
}

fn nested(arms: List(Arm), side: Side) -> String {
  case arms {
    [] -> "core.Done"
    [only] -> carried(only, side)
    [first, ..rest] ->
      side.choice
      <> "("
      <> carried(first, side)
      <> ", "
      <> nested(rest, side)
      <> ")"
  }
}

fn carried(arm: Arm, side: Side) -> String {
  side.carries <> "(" <> arm.payload <> ", " <> arm.next <> ")"
}

/// What a level of the nesting is, in prose. The outermost one is the choice
/// itself; the rest are what is left of it.
fn annotate(
  origin: String,
  marker: String,
  arms: List(Arm),
  side: Side,
) -> List(String) {
  let lead = case marker == origin {
    True -> wrap(side.lead)
    False ->
      wrap(
        "The arms of `"
        <> origin
        <> "` that are still open once the earlier ones have been ruled out.",
      )
  }

  let items =
    list.map(arms, fn(arm) {
      "- `"
      <> arm.label
      <> "` carrying `"
      <> arm.payload
      <> "`, then `"
      <> arm.next
      <> "`"
    })

  list.flatten([lead, [""], items])
}

/// One function per arm, walking the nesting so nobody else has to.
fn shortcuts(
  unfolds: List(String),
  state: State,
  arms: List(Arm),
  side: Side,
  taken: Taken,
) -> #(List(Helper), Taken) {
  let numbered = list.index_map(arms, fn(arm, index) { #(index, arm) })

  list.fold(numbered, #([], taken), fn(acc, entry) {
    let #(built, taken) = acc
    let #(index, arm) = entry
    let #(name, taken) =
      claim_value(snake(state.name) <> "_" <> snake(arm.label), taken)

    let helper =
      Helper(
        name:,
        marker: state.name,
        shape: carried(arm, side),
        steps: route(index, unfolds, side),
        note: wrap(
          side.take
          <> " the `"
          <> arm.label
          <> "` arm of `"
          <> state.name
          <> "`, which continues at `"
          <> arm.next
          <> "`.",
        ),
      )

    #(list.append(built, [helper]), taken)
  })
}

/// The steps from a choice's outermost position to its `index`th arm.
///
/// Every arm but the last is a run of right turns followed by a left one; the
/// last is right turns all the way down, because the bottom level holds two
/// arms rather than one.
fn route(index: Int, unfolds: List(String), side: Side) -> List(String) {
  case index, unfolds {
    0, [unfold, ..] -> [unfold, side.left]
    _, [unfold] -> [unfold, side.right]
    _, [unfold, ..rest] -> [unfold, side.right, ..route(index - 1, rest, side)]
    _, [] -> []
  }
}

// NAMES

fn claim_tails(
  origin: String,
  remaining: Int,
  taken: Taken,
  built: List(#(String, String)),
) -> #(List(#(String, String)), Taken) {
  case remaining > 0 {
    False -> #(built, taken)
    True -> {
      let #(marker, taken) = claim_type(origin <> "Otherwise", taken)
      let #(unfold, taken) = claim_value(snake(marker), taken)
      claim_tails(
        origin,
        remaining - 1,
        taken,
        list.append(built, [#(marker, unfold)]),
      )
    }
  }
}

fn claim_type(base: String, taken: Taken) -> #(String, Taken) {
  let name = unique(base, taken.types, 1)
  #(name, Taken(..taken, types: [name, ..taken.types]))
}

fn claim_value(base: String, taken: Taken) -> #(String, Taken) {
  let base = case list.contains(reserved, base) {
    True -> base <> "_"
    False -> base
  }
  let name = unique(base, taken.values, 1)
  #(name, Taken(..taken, values: [name, ..taken.values]))
}

fn unique(base: String, used: List(String), attempt: Int) -> String {
  let candidate = case attempt {
    1 -> base
    _ -> base <> int.to_string(attempt)
  }

  case list.contains(used, candidate) {
    True -> unique(base, used, attempt + 1)
    False -> candidate
  }
}

/// Gleam's keywords, plus the words it holds back for later. `derive` is on
/// the second list, and a generated function that happened to be called that
/// produces a syntax error pointing at an unrelated line.
const reserved = [
  "as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else",
  "fn", "if", "implement", "import", "let", "macro", "opaque", "panic", "pub",
  "test", "todo", "type", "use",
]

// RENDERING

const width = 80

fn render(protocol: Protocol, projected: Graph, prefix: String) -> Module {
  let name = module_name(protocol, projected, prefix)

  Module(name:, source: source(protocol, projected, layout(projected)))
}

fn module_name(protocol: Protocol, projected: Graph, prefix: String) -> String {
  let tail = snake(protocol.name) <> "/" <> snake(projected.role)

  case prefix {
    "" -> tail
    _ -> prefix <> "/" <> tail
  }
}

fn source(protocol: Protocol, projected: Graph, plan: Layout) -> String {
  let sections = [
    heading(protocol, projected),
    imports(protocol),
    "// POSITIONS",
    plan.positions
      |> list.map(declaration)
      |> string.join("\n\n"),
    "// OPENING",
    opening(protocol, projected),
    "// UNFOLDING",
    plan.positions
      |> list.map(unfolding)
      |> string.join("\n\n"),
  ]

  let sections = case plan.helpers {
    [] -> sections
    _ ->
      list.append(sections, [
        "// CHOICES",
        plan.helpers
          |> list.map(shortcut)
          |> string.join("\n\n"),
      ])
  }

  string.join(sections, "\n\n") <> "\n"
}

fn heading(protocol: Protocol, projected: Graph) -> String {
  [
    "////",
    ..list.map(
      list.flatten([
        wrap(
          "The `"
          <> projected.role
          <> "` view of the `"
          <> protocol.name
          <> "` protocol, written by `eparch/protocol/emit`.",
        ),
        [""],
        wrap(
          "Edits here are lost the next time it is generated. Change the"
          <> " specification instead.",
        ),
        [""],
        wrap(
          "Each position below is an uninhabited type. The function named after"
          <> " it unfolds it into the `eparch/session/core` shape the protocol"
          <> " says it has, one step deep, and everything after that is an"
          <> " ordinary `core` or `eparch/protocol_machine` call.",
        ),
      ]),
      comment("////"),
    )
  ]
  |> string.join("\n")
  <> "\n////"
}

fn imports(protocol: Protocol) -> String {
  [
    "import eparch/session/core.{type Channel}",
    "import gleam/erlang/process.{type Pid}",
    ..protocol.imports
  ]
  |> list.unique
  |> list.sort(string.compare)
  |> string.join("\n")
}

fn declaration(position: Position) -> String {
  documentation(position.note) <> "pub type " <> position.marker
}

fn opening(protocol: Protocol, projected: Graph) -> String {
  let note =
    list.flatten([
      wrap("Open a channel to `peer` at the start of the protocol."),
      [""],
      wrap(
        "No monitor is installed. Call `core.watch` from the process that will"
        <> " own the channel if this side needs to see the peer die.",
      ),
    ])

  documentation(note)
  <> "pub fn begin(peer: Pid) -> Channel("
  <> projected.initial
  <> ", msg) {\n  core.begin(peer, protocol: \""
  <> protocol.name
  <> "\")\n}"
}

fn unfolding(position: Position) -> String {
  documentation(position.note)
  <> signature(position.unfold, position.marker, position.shape)
  <> "\n  core.unchecked_position(channel)\n}"
}

fn shortcut(helper: Helper) -> String {
  documentation(helper.note)
  <> signature(helper.name, helper.marker, helper.shape)
  <> "\n"
  <> pipeline(helper.steps)
  <> "\n}"
}

/// A function head, broken where the formatter would break it.
///
/// The opening brace is left out of every measurement on purpose: `gleam
/// format` decides whether a signature fits by looking at the signature, and
/// puts the brace on the end afterwards. Counting it here breaks agreement on
/// exactly the lines that land on the margin.
fn signature(name: String, marker: String, shape: String) -> String {
  let parameter = "channel: Channel(" <> marker <> ", msg)"
  let returns = ") -> Channel(" <> shape <> ", msg)"
  let flat = "pub fn " <> name <> "(" <> parameter <> returns

  case string.length(flat) <= width {
    True -> flat <> " {"
    False -> {
      let head = "pub fn " <> name <> "(\n  " <> parameter <> ",\n"

      case string.length(returns) <= width {
        True -> head <> returns <> " {"
        False -> head <> ") -> Channel(\n  " <> shape <> ",\n  msg,\n) {"
      }
    }
  }
}

fn pipeline(steps: List(String)) -> String {
  let parts = ["channel", ..steps]
  let flat = "  " <> string.join(parts, " |> ")

  case string.length(flat) <= width {
    True -> flat
    False -> "  " <> string.join(parts, "\n  |> ")
  }
}

fn documentation(note: List(String)) -> String {
  case note {
    [] -> ""
    _ ->
      note
      |> list.map(comment("///"))
      |> string.join("\n")
      <> "\n///\n"
  }
}

fn comment(marker: String) -> fn(String) -> String {
  fn(line) {
    case line {
      "" -> marker
      _ -> marker <> " " <> line
    }
  }
}

/// Break a sentence into doc-comment lines. The formatter leaves comments
/// alone, so this is the only thing keeping them inside the margin.
fn wrap(text: String) -> List(String) {
  let room = width - 4

  string.split(text, " ")
  |> list.filter(fn(word) { word != "" })
  |> list.fold([], fn(lines, word) {
    case lines {
      [] -> [word]
      [current, ..rest] -> {
        let joined = current <> " " <> word

        case string.length(joined) <= room {
          True -> [joined, ..rest]
          False -> [word, ..lines]
        }
      }
    }
  })
  |> list.reverse
}

fn snake(name: String) -> String {
  let #(built, _) =
    list.fold(string.to_graphemes(name), #("", ""), fn(acc, char) {
      let #(built, previous) = acc

      case
        capital(char) && previous != "" && previous != "_" && !capital(previous)
      {
        True -> #(built <> "_" <> string.lowercase(char), char)
        False -> #(built <> string.lowercase(char), char)
      }
    })

  built
}

fn capital(char: String) -> Bool {
  char != string.lowercase(char)
}
