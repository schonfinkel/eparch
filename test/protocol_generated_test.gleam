////
//// Tests for generated protocol modules, run against the modules committed
//// under `test/generated`.
////
//// These are the only tests in the repo that check the emitter's output the
//// way a user meets it: by compiling it. A test asserting that the emitter
//// produced a particular string proves the string, and nothing about whether
//// the string is a Gleam module that says what it meant to. Committing the
//// output and building on it proves the rest, and the round-trip test at the
//// bottom is what stops the committed copy drifting from the specification.
////
//// The machine below is the real point. Its protocol loops, so it could not
//// have been written by hand at all: a nested type that returns to an earlier
//// position is an alias defined in terms of itself, which the compiler
//// rejects. Every position it visits is a generated name, and every step it
//// takes goes through a generated route.
////

import atm_protocol.{type Amount, type CardId}
import eparch/protocol/emit
import eparch/protocol/graph
import eparch/protocol/relations
import eparch/protocol_machine as pm
import eparch/session/core.{type Channel}
import eparch/state_machine
import generated/atm/customer
import generated/atm/teller
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

// THE TELLER, AS A MACHINE

type Wire {
  /// The customer's card, at the start.
  Card(CardId)
  /// The three arms of the choice the customer makes, over and over.
  Deposit(Amount)
  Withdraw(Amount)
  Quit
  /// Internal: wake a position that has nothing to wait for.
  Proceed
}

type Tag {
  Reading
  Serving
  Reporting
  Dispensing
  Closed
}

/// One alias, so no position function has to name five type parameters.
type Position(protocol) =
  pm.ProtocolState(protocol, Tag, Amount, Wire, String)

fn at_greeting(
  channel: Channel(teller.Greeting, Wire),
  balance: Amount,
  report: Subject(String),
) -> Position(teller.Greeting) {
  pm.state(
    tag: Reading,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event {
        state_machine.Cast(Card(id)) ->
          pm.along(at: channel, route: teller.greeting, step: fn(channel) {
            pm.accept(at: channel, message: id, actions: [], then: fn(next) {
              process.send(report, "card:" <> id)
              at_session(next, balance, report)
            })
          })

        _ -> pm.postpone()
      }
    },
  )
}

/// The position the loop returns to, and the reason this protocol needed a
/// generator. Three arms, so `core`'s binary branching nests, and each route
/// below walks the whole nest in one step.
fn at_session(
  channel: Channel(teller.Session, Wire),
  balance: Amount,
  report: Subject(String),
) -> Position(teller.Session) {
  pm.state(
    tag: Serving,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event {
        state_machine.Cast(Deposit(amount)) ->
          pm.along(
            at: channel,
            route: teller.session_deposit,
            step: fn(channel) {
              pm.accept(
                at: channel,
                message: amount,
                actions: [pm.advance_now(Proceed)],
                then: fn(next) { at_balance(next, balance + amount, report) },
              )
            },
          )

        state_machine.Cast(Withdraw(amount)) ->
          pm.along(
            at: channel,
            route: teller.session_withdraw,
            step: fn(channel) {
              pm.accept(
                at: channel,
                message: amount,
                actions: [pm.advance_now(Proceed)],
                then: fn(next) { at_cash(next, balance - amount, report) },
              )
            },
          )

        state_machine.Cast(Quit) ->
          pm.along(at: channel, route: teller.session_quit, step: fn(channel) {
            pm.accept(
              at: channel,
              message: Nil,
              actions: [pm.advance_now(Proceed)],
              then: fn(next) { at_ended(next, balance, report) },
            )
          })

        _ -> pm.postpone()
      }
    },
  )
}

fn at_balance(
  channel: Channel(teller.AtBalance, Wire),
  balance: Amount,
  report: Subject(String),
) -> Position(teller.AtBalance) {
  pm.state(
    tag: Reporting,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event {
        state_machine.Cast(Proceed) ->
          pm.along(at: channel, route: teller.at_balance, step: fn(channel) {
            pm.transmit(
              at: channel,
              message: balance,
              actions: [],
              then: fn(amount, next) {
                process.send(report, "balance:" <> int.to_string(amount))
                // Straight back to the head of the loop.
                at_session(next, balance, report)
              },
            )
          })

        _ -> pm.postpone()
      }
    },
  )
}

fn at_cash(
  channel: Channel(teller.AtCash, Wire),
  balance: Amount,
  report: Subject(String),
) -> Position(teller.AtCash) {
  pm.state(
    tag: Dispensing,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event {
        state_machine.Cast(Proceed) ->
          pm.along(at: channel, route: teller.at_cash, step: fn(channel) {
            pm.transmit(
              at: channel,
              message: balance,
              actions: [],
              then: fn(amount, next) {
                process.send(report, "cash:" <> int.to_string(amount))
                at_session(next, balance, report)
              },
            )
          })

        _ -> pm.postpone()
      }
    },
  )
}

fn at_ended(
  channel: Channel(teller.Ended, Wire),
  balance: Amount,
  report: Subject(String),
) -> Position(teller.Ended) {
  pm.state(
    tag: Closed,
    at: channel,
    data: balance,
    handler: fn(event, channel, balance) {
      case event {
        state_machine.Cast(Proceed) -> {
          process.send(report, "closed:" <> int.to_string(balance))
          pm.along(at: channel, route: teller.ended, step: fn(channel) {
            pm.complete(at: channel, actions: [])
          })
        }

        _ -> pm.postpone()
      }
    },
  )
}

fn start(report: Subject(String)) -> state_machine.Started(Wire) {
  let assert Ok(started) =
    pm.new(at_greeting(teller.begin(process.self()), 0, report))
    |> pm.start_link

  started
}

// THE MACHINE, END TO END

pub fn a_generated_protocol_drives_a_real_machine_test() {
  let report = process.new_subject()
  let started = start(report)
  let monitor = process.monitor(started.pid)

  state_machine.cast(started.ref, Card("4111"))
  state_machine.cast(started.ref, Deposit(100))
  state_machine.cast(started.ref, Withdraw(30))
  state_machine.cast(started.ref, Deposit(5))
  state_machine.cast(started.ref, Quit)

  assert process.receive(report, within: 1000) == Ok("card:4111")
  assert process.receive(report, within: 1000) == Ok("balance:100")
  assert process.receive(report, within: 1000) == Ok("cash:70")
  assert process.receive(report, within: 1000) == Ok("balance:75")
  assert process.receive(report, within: 1000) == Ok("closed:75")

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(reason:, ..)) =
    process.selector_receive(from: selector, within: 1000)

  assert reason == process.Normal
}

pub fn the_loop_goes_round_as_many_times_as_it_is_asked_to_test() {
  let report = process.new_subject()
  let started = start(report)

  state_machine.cast(started.ref, Card("4111"))
  let assert Ok("card:4111") = process.receive(report, within: 1000)

  // Ten times round a cycle no nested type could have expressed at all.
  list.each(list.repeat(Nil, 10), fn(_) {
    state_machine.cast(started.ref, Deposit(10))
  })

  let seen =
    list.map(list.repeat(Nil, 10), fn(_) {
      let assert Ok(line) = process.receive(report, within: 1000)
      line
    })

  assert list.last(seen) == Ok("balance:100")

  state_machine.cast(started.ref, Quit)
  assert process.receive(report, within: 1000) == Ok("closed:100")
}

pub fn the_tag_of_a_generated_position_is_what_gen_statem_sees_test() {
  let report = process.new_subject()
  let started = start(report)

  assert string.contains(sys_get_status(started.pid), "reading")

  state_machine.cast(started.ref, Card("4111"))
  let assert Ok("card:4111") = process.receive(report, within: 1000)

  assert string.contains(sys_get_status(started.pid), "serving")
}

// THE CUSTOMER, WALKED BY HAND
//
// The other side of the same protocol, without a machine. Every line here is
// a position change the compiler had to agree to, so the test passing is the
// smaller half of what it demonstrates.

pub fn the_other_side_walks_the_same_loop_test() {
  let channel = customer.begin(process.self())
  let #(card, channel) = core.send(customer.greeting(channel), "4111")

  let #(deposited, channel) = core.send(customer.session_deposit(channel), 100)
  let channel = core.receive(customer.at_balance(channel), 100)

  let #(withdrawn, channel) = core.send(customer.session_withdraw(channel), 30)
  let channel = core.receive(customer.at_cash(channel), 70)

  let #(Nil, channel) = core.send(customer.session_quit(channel), Nil)
  let details = core.finish(customer.ended(channel))

  assert card == "4111"
  assert deposited == 100
  assert withdrawn == 30
  assert details.protocol_name == "atm"
}

pub fn the_two_generated_views_are_duals_test() {
  // The modules are written from these graphs, so a duality failure here would
  // mean the two files could not be talking to each other.
  let assert Ok([customer, teller]) = graph.compile(atm_protocol.atm())
  let assert Ok(_) = relations.dual(customer, teller)
}

// THE COMMITTED COPY IS STILL THE RIGHT ONE

pub fn the_generated_modules_on_disk_are_up_to_date_test() {
  // What `gleam run -m protocol_generate check` does, as a test, so a changed
  // specification cannot reach main with stale modules beside it.
  let assert Ok(wanted) = emit.modules(atm_protocol.atm(), under: "generated")

  let reviews =
    emit.review(wanted, against: fn(module) {
      simplifile.read(emit.path(module, in: "test"))
      |> result.replace_error(Nil)
    })

  assert list.map(reviews, emit.describe)
    == [
      "generated/atm/customer: up to date",
      "generated/atm/teller: up to date",
    ]
}

@external(erlang, "eparch_test_helpers", "sys_get_status_text")
fn sys_get_status(pid: process.Pid) -> String
