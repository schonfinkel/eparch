//// The protocol specification language.
////
//// A specification is an ordinary Gleam value rather than a file some parser
//// has to be taught to read, so the Gleam compiler rejects a malformed
//// specification before the generator ever runs. 
////
//// ## Why this layer exists
////
//// `eparch/session/core` encodes a protocol as a nested type, which is what
//// makes duality provable by an ordinary value. It is also why that encoding
//// cannot repeat: a protocol that loops would need a type alias defined in
//// terms of itself, and Gleam rejects that outright.
////
//// ```
//// error: Type cycle
//// This type alias is defined in terms of itself.
//// ```
////
//// A specification sidesteps the problem by never being a type. The generator
//// flattens it into a state graph and emits one uninhabited marker per state,
//// so a loop becomes an edge back to an earlier marker. Nothing recursive is
//// ever emitted, and nothing the compiler rejects is ever produced.
////
//// The second thing this layer buys is participants. `session/core` is
//// two-party by construction, because a channel has exactly one peer. A
//// specification names any number of roles and projects onto each of them.
////
//// ## A protocol
////
//// ```gleam
//// spec.Protocol(
////   name: "atm",
////   roles: ["Customer", "Teller"],
////   initial: "Greeting",
////   imports: ["import atm/money.{type Amount, type CardId}"],
////   spec: spec.Message(
////     from: "Customer",
////     to: "Teller",
////     label: "card",
////     payload: "CardId",
////     then: spec.Loop("session", spec.Choice(
////       at: "Customer",
////       to: "Teller",
////       branches: [
////         spec.Branch("deposit", "Amount", spec.Message(
////           from: "Teller", to: "Customer",
////           label: "balance", payload: "Amount",
////           then: spec.Continue("session"),
////         )),
////         spec.Branch("quit", "Nil", spec.End),
////       ],
////     )),
////   ),
//// )
//// ```
////
//// ## Payload types are names, not types
////
//// `payload` is a string naming a Gleam type, resolved by the `imports` lines
//// emitted verbatim into every generated module. Nothing else can work: Gleam
//// has no type reflection, so a specification that is a value cannot hold a
//// type. The cost is that a misspelled payload is caught by the compiler on
//// the generated module rather than by the generator, which is a good enough
//// place to catch it.
////
//// ## Contact points
////
//// `Assert`, `Require` and `Consume` annotate a protocol with what it
//// guarantees and what it needs, following Bocchi, Orchard and Voinea's
//// [A Theory of Composing Protocols (2022)](https://arxiv.org/pdf/2203.02461)
//// 
//// They describe no communication and are erased before any code is emitted. 
//// Two things read them:
////
//// - `eparch/protocol/graph` checks them for consistency, so a protocol that
////   requires something it never asserted is rejected on its own, before
////   anything is composed with it.
//// - Interleaving composition uses them to work out which weavings of two
////   protocols are valid.
////
//// The distinction that matters is linear against non-linear. `Require` needs
//// a guarantee and leaves it in place, so a PIN checked once covers a whole
//// session. `Consume` needs it and spends it, so a one-time code covers
//// exactly one payment.
////

/// A protocol between two or more participants.
///
/// ## Example
///
/// ```gleam
/// spec.Protocol(
///   name: "ping_pong",
///   roles: ["Client", "Server"],
///   initial: "Asking",
///   imports: [],
///   spec: spec.Message("Client", "Server", "ping", "Nil", spec.End),
/// )
/// ```
///
pub type Protocol {
  Protocol(
    /// Names the generated modules and the directory they land in.
    name: String,
    /// Every participant. Projection produces one graph per entry.
    roles: List(String),
    /// What to call the state the protocol starts in.
    initial: String,
    /// Import lines emitted verbatim into every generated module, so the
    /// payload type names below resolve. For example
    /// `["import atm/money.{type CardId}"]`.
    imports: List(String),
    spec: Spec,
  )
}

/// One step of a conversation, and everything that follows it.
///
pub type Spec {
  /// `from` transmits `payload` to `to`, then the protocol continues.
  ///
  /// Both participants advance; everybody else is unaffected and their
  /// projection skips straight past this step.
  Message(from: String, to: String, label: String, payload: String, then: Spec)

  /// `at` picks a branch and tells `to` which one by its label.
  ///
  /// The choice is directed, naming both who decides and who is told, because
  /// that is what makes projection well defined once there are more than two
  /// participants. For `at` this is an internal choice, for `to` an external
  /// one, and for everybody else an obligation: their view of every branch has
  /// to be mergeable, since they are never told which was taken.
  Choice(at: String, to: String, branches: List(Branch))

  /// Bind `name` to the state at this point, so `Continue(name)` can return to
  /// it. This is the construct the nested type encoding cannot express.
  Loop(name: String, body: Spec)

  /// Return to a bound loop.
  ///
  /// This constructor carries no continuation, which makes non-tail recursion
  /// unrepresentable rather than merely rejected. A protocol recursing in a
  /// non-tail position would need a stack, and the whole point of flattening is
  /// to land on a finite state graph.
  Continue(name: String)

  /// Give the state at this point an explicit name in the generated code.
  ///
  /// Purely cosmetic. Unnamed states are named after the step they perform and
  /// numbered when that collides.
  At(name: String, then: Spec)

  /// Introduce the guarantee `name` from this point on.
  Assert(name: String, then: Spec)

  /// Demand the guarantee `name` without spending it.
  ///
  /// Non-linear: the guarantee survives, so one assertion covers any number of
  /// requirements.
  Require(name: String, then: Spec)

  /// Demand the guarantee `name` and spend it.
  ///
  /// Linear: the guarantee is gone afterwards, so a second `Consume` of the
  /// same name needs a second `Assert`.
  Consume(name: String, then: Spec)

  /// The conversation is over and no participant owes another anything.
  End
}

/// One arm of a `Choice`.
///
/// The label is what the deciding participant transmits, so labels within one
/// choice have to differ. `payload` names the type carried alongside it, or
/// `"Nil"` for a bare label.
///
pub type Branch {
  Branch(label: String, payload: String, then: Spec)
}

/// The other participant, for a protocol that has exactly two.
///
/// Returns `Error(Nil)` if the protocol is not two-party or `role` is not one
/// of its participants.
///
/// ## Example
///
/// ```gleam
/// let assert Ok("Teller") = spec.counterpart(atm(), "Customer")
/// ```
///
pub fn counterpart(protocol: Protocol, role: String) -> Result(String, Nil) {
  case protocol.roles {
    [left, right] if role == left -> Ok(right)
    [left, right] if role == right -> Ok(left)
    _ -> Error(Nil)
  }
}
