////
//// The ATM example, run end to end.
////
//// ```sh
//// gleam run
//// ```
////
//// Two sessions against two machines, one for each of the paper's client
//// programs. The output is a transcript; the point is that every step in it was
//// checked against the protocol before it ran.
////

import atm/client
import atm/machine
import atm/money.{type Amount}
import gleam/erlang/process
import gleam/int
import gleam/io

pub fn main() -> Nil {
  io.println("The ATM protocol, from Laumann, Munksgaard and Larsen (2015).\n")

  figure_11()
  io.println("")
  figure_12()
  io.println("")
  refused_card()
}

/// Figure 11: a client who pays money in.
fn figure_11() -> Nil {
  io.println("A client deposits 120 into an account holding 500:")

  let inbox = process.new_subject()
  let assert Ok(atm) = machine.start(serving: inbox, holding: 500)

  case client.deposit(120, at: atm, from: inbox, with: "4111") {
    Ok(balance) -> io.println("  new balance: " <> money(balance))
    Error(trouble) -> io.println("  no good: " <> string_of(trouble))
  }
}

/// Figure 12: a client who asks for more than is there, and pays in instead.
fn figure_12() -> Nil {
  io.println("A client asks a nearly empty machine for 200, falling back to a")
  io.println("deposit of 50:")

  let inbox = process.new_subject()
  let assert Ok(atm) = machine.start(serving: inbox, holding: 30)

  let asked =
    client.withdraw(200, at: atm, from: inbox, with: "4111", paying: 50)

  case asked {
    Ok(client.Paid(cash)) -> io.println("  dispensed: " <> money(cash))
    Ok(client.Overdrawn(balance)) ->
      io.println("  declined, balance now: " <> money(balance))
    Error(trouble) -> io.println("  no good: " <> string_of(trouble))
  }
}

/// The `err` arm of the first choice, which the paper's clients handle in their
/// first three lines and which is easy to forget exists.
fn refused_card() -> Nil {
  io.println("A client puts in a card the machine will not take:")

  let inbox = process.new_subject()
  let assert Ok(atm) = machine.start(serving: inbox, holding: 500)

  case client.deposit(120, at: atm, from: inbox, with: "") {
    Ok(balance) -> io.println("  new balance: " <> money(balance))
    Error(trouble) -> io.println("  " <> string_of(trouble))
  }
}

fn money(amount: Amount) -> String {
  int.to_string(amount)
}

fn string_of(trouble: client.Trouble) -> String {
  case trouble {
    client.CardRejected -> "the machine kept the card"
    client.NoAnswer -> "the machine stopped talking"
    client.Unexpected(_) -> "the machine is not speaking this protocol"
  }
}
