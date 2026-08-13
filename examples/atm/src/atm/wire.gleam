////
//// What actually crosses between the two processes.
////
//// The protocol layer never sees this type. A specification names payload
//// types (`CardId`, `Amount`) and branch labels (`deposit`, `ok`), and stops
//// there, because how a label is spelled on the wire is a decision about the
//// transport rather than about the protocol. This module is where that decision
//// is made, and it is made once for both sides: the machine in `atm/machine`
//// and the client in `atm/client` speak the same `Wire`.
////
//// ## Labels are messages
////
//// The four bare constructors below carry nothing, because the four branch
//// labels they stand for carry `"Nil"`. That is the paper's point about
//// `⊕{ok : ε, err : ε}`:
////
//// > branches can be used to convey information by themselves: The client knows
//// > that if the err branch is taken, the request was unsuccessful.
////
//// `Approved` *is* the good news. There is no separate outcome field that can
//// disagree with the branch that was taken, because there is no separate field.
////
//// ## Why one type and not two
////
//// A `Channel(protocol, msg)` pins `msg` for the whole conversation, so both
//// directions share one type. Which of its constructors may cross at any given
//// moment is not this type's business: that is what the position is for, and
//// sending `Balance` where the protocol wants `Approved` fails to compile at
//// the step that tries it.
////

import atm/money.{type Amount, type CardId}

/// Every message either side can put on the wire.
///
pub type Wire {
  /// `Client → Atm`: the card, at the start. Carries `CardId`.
  Card(CardId)

  /// `Atm → Client`: the `ok` arm of the screening choice. The session
  /// continues.
  Approved

  /// `Atm → Client`: the `err` arm of the screening choice. The session is
  /// over.
  Rejected

  /// `Client → Atm`: the `deposit` arm. Carries the `Amount` to pay in.
  Deposit(Amount)

  /// `Client → Atm`: the `withdraw` arm. Carries the `Amount` asked for.
  Withdraw(Amount)

  /// `Client → Atm`: the `quit` arm. The session is over.
  Quit

  /// `Atm → Client`: the balance after a deposit. Carries `Amount`.
  Balance(Amount)

  /// `Atm → Client`: the `ok` arm of the withdrawal choice. The money is on its
  /// way out of the slot.
  Dispensed

  /// `Atm → Client`: the `err` arm of the withdrawal choice. Not enough in the
  /// account, and the session carries on regardless.
  Declined

  /// Neither direction: the machine waking itself up.
  ///
  /// A `gen_statem` only acts when an event arrives, and a position where it is
  /// this side's turn to speak has nothing to wait for. The machine hands
  /// itself this as an internal event to get moving. It never leaves the
  /// process, and the client never sends it.
  Proceed
}
