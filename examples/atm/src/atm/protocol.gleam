////
//// The ATM protocol, transcribed from Laumann, Munksgaard and Larsen,
//// *Session Types for Rust* (WGP 2015), §2.2.
////
//// The paper states it twice: in prose, and as a pair of session types. The
//// prose reads:
////
//// > - The CLIENT communicates his/her ID to the ATM
//// > - The ATM then answers either ok or err
//// >   - In the first case, the CLIENT then proceeds to request either a
//// >     deposit or withdraw
//// >     - For a deposit the CLIENT first sends an amount, then the ATM
//// >       responds with the updated balance
//// >     - For a withdraw the CLIENT sends the amount to withdraw, and the ATM
//// >       responds with either ok or err to indicate whether or not the
//// >       transaction was successful
//// >
//// > If the ATM answers err, then the session terminates.
////
//// and the types, from the ATM's point of view, with the recursion the paper
//// adds a page later so that a client may perform more than one transaction:
////
//// ```text
//// ATM  = ?[id]; ⊕{ok : ATM', err : ε}
//// ATM' = µt.&{ deposit  : ?[u64]; ![u64]; t,
////              withdraw : ?[u64]; ⊕{ok : t, err : t},
////              quit     : ε
////            }
//// ```
////
//// ## How that maps onto `eparch/protocol/spec`
////
//// The paper writes one side and derives the other by duality. A specification
//// here is *global*: it describes the conversation rather than either
//// participant, and `eparch/protocol/graph` projects it onto both. So `?` and
//// `!` become one `Message` naming who speaks and who listens, and `⊕` and `&`
//// become one `Choice` naming who decides and who is told.
////
//// | Paper | Here |
//// |---|---|
//// | `?[id]; α` at the ATM | `Message(from: "Client", to: "Atm", label: "card", payload: "CardId", …)` |
//// | `⊕{ok : …, err : …}` at the ATM | `Choice(at: "Atm", to: "Client", branches: […])` |
//// | `&{deposit : …, …}` at the ATM | `Choice(at: "Client", to: "Atm", branches: […])` |
//// | `µt.α` | `Loop("session", …)` |
//// | `t` | `Continue("session")` |
//// | `ε` | `End` |
////
//// A `Choice` names both the participant deciding and the participant being
//// told, which `⊕`/`&` do not have to: with exactly two participants the other
//// one is implied. Naming it is what keeps projection well defined when a third
//// participant is added, since somebody who is never told which arm was taken
//// has to behave the same either way.
////
//// ## What the labels carry
////
//// `ok` and `err` carry `"Nil"` on purpose. The paper makes a point of it:
////
//// > Its final `⊕{ok : ε, err : ε}` may seem redundant, but it demonstrates how
//// > branches can be used to convey information by themselves: The client knows
//// > that if the err branch is taken, the request was unsuccessful.
////
//// The label *is* the message. There is no separate outcome value to get out of
//// step with the branch that was taken, because the branch is the outcome.
////

import eparch/protocol/spec
import gleam/list

/// The ATM protocol as one global specification.
///
/// Two participants, two choices made by opposite sides, a loop around the
/// three-armed one, and two ways to reach the end. Everything downstream comes
/// from this value: the generated modules under `generated/atm`, the duality
/// and subtyping checks in the tests, and the positions the machine in
/// `atm/machine` is written against.
///
/// ## Example
///
/// ```gleam
/// let assert Ok([client, atm]) = graph.compile(protocol.atm())
/// let assert Ok(_) = relations.dual(client, atm)
/// ```
///
pub fn atm() -> spec.Protocol {
  protocol(session(offering: []))
}

/// The same protocol with the paper's §4.3 extension: a `balance` arm that asks
/// what is in the account without moving any money.
///
/// Nothing is generated from this one. It exists to be *compared* against
/// `atm`, which is the question anybody changing a live protocol actually has:
/// will the participants already out there keep working? `relations.subtype`
/// answers it, and the answer is not the same in both directions. See
/// `atm_test`.
///
/// The paper reaches the same question and has to answer it by hand:
///
/// > Extending a protocol might require users to take into account parts of the
/// > protocol that they are not interested in.
///
/// which is what happens when the way to name an arm is to count past the ones
/// before it.
///
pub fn atm_with_balance() -> spec.Protocol {
  protocol(
    session(offering: [
      spec.Branch(
        "balance",
        "Nil",
        spec.At(
          "Quoting",
          spec.Message(
            from: "Atm",
            to: "Client",
            label: "balance",
            payload: "Amount",
            then: spec.Continue("session"),
          ),
        ),
      ),
    ]),
  )
}

/// Everything both versions share: `?[id]; ⊕{ok : …, err : ε}` wrapped around
/// whichever session was handed in.
fn protocol(session: spec.Spec) -> spec.Protocol {
  spec.Protocol(
    name: "atm",
    roles: ["Client", "Atm"],
    initial: "AwaitingCard",
    imports: ["import atm/money.{type Amount, type CardId}"],
    // ?[id]
    spec: spec.Message(
      from: "Client",
      to: "Atm",
      label: "card",
      payload: "CardId",
      // ⊕{ok : ATM', err : ε}
      then: spec.At(
        "Screening",
        spec.Choice(at: "Atm", to: "Client", branches: [
          spec.Branch("ok", "Nil", session),
          spec.Branch("err", "Nil", spec.End),
        ]),
      ),
    ),
  )
}

/// `ATM' = µt.&{…}`: the part a client may repeat.
///
/// Split out because it is the paper's second type, not because the
/// specification needs it in two pieces. `Loop` binds the name `session` to the
/// state at its head, and every `Continue("session")` below is an edge back to
/// it.
///
/// `offering` is spliced in ahead of `quit`, which is where the paper puts its
/// added branch. Where an arm sits matters in the paper's encoding, because its
/// clients name arms by counting past the ones before them; here the arms have
/// names, and the order only decides how the generated routes nest.
fn session(offering extra: List(spec.Branch)) -> spec.Spec {
  spec.Loop(
    "session",
    spec.At(
      "Serving",
      spec.Choice(
        at: "Client",
        to: "Atm",
        branches: list.flatten([
          [
            // deposit : ?[u64]; ![u64]; t
            spec.Branch(
              "deposit",
              "Amount",
              spec.At(
                "Reporting",
                spec.Message(
                  from: "Atm",
                  to: "Client",
                  label: "balance",
                  payload: "Amount",
                  then: spec.Continue("session"),
                ),
              ),
            ),
            // withdraw : ?[u64]; ⊕{ok : t, err : t}
            spec.Branch(
              "withdraw",
              "Amount",
              spec.At(
                "Assessing",
                spec.Choice(at: "Atm", to: "Client", branches: [
                  spec.Branch("ok", "Nil", spec.Continue("session")),
                  spec.Branch("err", "Nil", spec.Continue("session")),
                ]),
              ),
            ),
          ],
          extra,
          // quit : ε
          [spec.Branch("quit", "Nil", spec.End)],
        ]),
      ),
    ),
  )
}
