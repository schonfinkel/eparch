////
//// The specification the committed modules under `test/generated` were
//// written from, and the payload types it names.
////
//// Keeping both in one module is not tidiness: a specification's payloads are
//// strings, and the only thing that resolves them is the import line it
//// carries, so the two have to agree and are easiest to keep agreeing side by
//// side.
////
//// Regenerating, after changing anything here:
////
//// ```sh
//// gleam run -m protocol_generate
//// ```
////

import eparch/protocol/spec

pub type Amount =
  Int

pub type CardId =
  String

/// Two participants, a loop, a choice of three, and a way out.
///
/// Chosen because it needs every part of the emitter at once: a send, a
/// receive, a choice wide enough to nest past `core`'s binary branching, an
/// end state, and a back edge that no nested type could express.
///
pub fn atm() -> spec.Protocol {
  spec.Protocol(
    name: "atm",
    roles: ["Customer", "Teller"],
    initial: "Greeting",
    imports: ["import atm_protocol.{type Amount, type CardId}"],
    spec: spec.Message(
      from: "Customer",
      to: "Teller",
      label: "card",
      payload: "CardId",
      then: spec.Loop(
        "session",
        spec.Choice(at: "Customer", to: "Teller", branches: [
          spec.Branch(
            "deposit",
            "Amount",
            spec.Message(
              from: "Teller",
              to: "Customer",
              label: "balance",
              payload: "Amount",
              then: spec.Continue("session"),
            ),
          ),
          spec.Branch(
            "withdraw",
            "Amount",
            spec.Message(
              from: "Teller",
              to: "Customer",
              label: "cash",
              payload: "Amount",
              then: spec.Continue("session"),
            ),
          ),
          spec.Branch("quit", "Nil", spec.End),
        ]),
      ),
    ),
  )
}
