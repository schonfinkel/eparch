////
//// Tests for the fragment-shaped transitions on `eparch/protocol_machine`.
////
//// What these check beyond "it runs" is that each helper collapses a whole
//// fragment into one transition. Written longhand, a receive followed by a
//// send needs two positions and an `advance_now` between them, because a
//// `Send` position has nothing to wait for. The tag assertions below are how
//// that shows: the machine is never observed at an intermediate position,
//// because there is not one.
////

import eparch/protocol_machine as pm
import eparch/session/core.{type Channel}
import eparch/session/patterns
import eparch/state_machine
import gleam/erlang/process.{type Subject}

// ANSWERING A REQUEST IN ONE STEP

type Lookup =
  patterns.Serve(String, Int, core.Done)

type Wire {
  Ask(String)
  Offer(Int)
  Proceed
  WhereAreWe
}

type Tag {
  Idle
  Settling
  WalkedAway
  Complete
}

type LookupPosition(protocol) =
  pm.ProtocolState(protocol, Tag, Nil, Wire, Tag)

fn idle(
  channel: Channel(Lookup, Wire),
  report: Subject(Int),
) -> LookupPosition(Lookup) {
  pm.state(tag: Idle, at: channel, data: Nil, handler: fn(event, channel, data) {
    case event {
      state_machine.Cast(Ask(question)) ->
        pm.answer(
          at: channel,
          question: question,
          with: fn(q) { string_length(q) },
          // No `advance_now` here: `answer` already performed both halves of
          // the fragment, so there is no sending position left to wake.
          actions: [],
          then: fn(answer, next) {
            process.send(report, answer)
            settled(next)
          },
        )

      state_machine.Call(from, WhereAreWe) ->
        pm.hold(data:, actions: [state_machine.reply(from, Idle)])

      _ -> pm.postpone()
    }
  })
}

fn settled(channel: Channel(core.Done, Wire)) -> LookupPosition(core.Done) {
  pm.state(
    tag: Complete,
    at: channel,
    data: Nil,
    handler: fn(event, channel, data) {
      case event {
        state_machine.Cast(Proceed) -> pm.complete(at: channel, actions: [])
        state_machine.Call(from, WhereAreWe) ->
          pm.hold(data:, actions: [state_machine.reply(from, Complete)])
        _ -> pm.postpone()
      }
    },
  )
}

@external(erlang, "string", "length")
fn string_length(value: String) -> Int

pub fn answer_completes_a_request_in_one_transition_test() {
  let report = process.new_subject()
  let channel: Channel(Lookup, Wire) =
    core.begin(process.self(), protocol: "lookup")

  let assert Ok(started) = pm.new(idle(channel, report)) |> pm.start_link

  // Before: the machine is idle.
  assert where(started) == Idle

  state_machine.cast(started.ref, Ask("balance"))
  assert process.receive(report, within: 1000) == Ok(7)

  // After: straight to the end. There is no intermediate sending position,
  // which is the whole point of `answer`.
  assert where(started) == Complete

  // Still alive at Done, and stops only when told to.
  assert process.is_alive(started.pid)
  state_machine.cast(started.ref, Proceed)
  process.sleep(50)
  assert !process.is_alive(started.pid)
}

// DECIDING A PROPOSAL IN ONE STEP

type Haggle =
  patterns.Decide(Int, patterns.Serve(String, String, core.Done), core.Done)

type HagglePosition(protocol) =
  pm.ProtocolState(protocol, Tag, Nil, Wire, Tag)

fn considering(
  channel: Channel(Haggle, Wire),
  budget: Int,
  report: Subject(String),
) -> HagglePosition(Haggle) {
  pm.state(tag: Idle, at: channel, data: Nil, handler: fn(event, channel, data) {
    case event {
      state_machine.Cast(Offer(price)) ->
        pm.decide(
          at: channel,
          proposal: price,
          choosing: fn(price) { price <= budget },
          actions: [],
          accepted: fn(next) {
            process.send(report, "accepted")
            settling(next)
          },
          rejected: fn(next) {
            process.send(report, "rejected")
            walked_away(next)
          },
        )

      state_machine.Call(from, WhereAreWe) ->
        pm.hold(data:, actions: [state_machine.reply(from, Idle)])

      _ -> pm.postpone()
    }
  })
}

fn settling(
  channel: Channel(patterns.Serve(String, String, core.Done), Wire),
) -> HagglePosition(patterns.Serve(String, String, core.Done)) {
  pm.state(
    tag: Settling,
    at: channel,
    data: Nil,
    handler: fn(event, channel, data) {
      case event {
        state_machine.Call(from, WhereAreWe) ->
          pm.hold(data:, actions: [state_machine.reply(from, Settling)])
        _ -> {
          let _ = channel
          pm.postpone()
        }
      }
    },
  )
}

fn walked_away(channel: Channel(core.Done, Wire)) -> HagglePosition(core.Done) {
  pm.state(
    tag: WalkedAway,
    at: channel,
    data: Nil,
    handler: fn(event, channel, data) {
      case event {
        state_machine.Call(from, WhereAreWe) ->
          pm.hold(data:, actions: [state_machine.reply(from, WalkedAway)])
        state_machine.Cast(Proceed) -> pm.complete(at: channel, actions: [])
        _ -> pm.postpone()
      }
    },
  )
}

fn start_haggle(
  budget: Int,
  report: Subject(String),
) -> state_machine.Started(Wire) {
  let channel: Channel(Haggle, Wire) =
    core.begin(process.self(), protocol: "haggle")
  let assert Ok(started) =
    pm.new(considering(channel, budget, report)) |> pm.start_link
  started
}

pub fn decide_takes_the_accepting_branch_test() {
  let report = process.new_subject()
  let started = start_haggle(1000, report)

  state_machine.cast(started.ref, Offer(500))

  assert process.receive(report, within: 1000) == Ok("accepted")
  // The two outcomes are genuinely different protocols, not one protocol
  // carrying a flag, so the machine lands at a different position for each.
  assert where(started) == Settling
}

pub fn decide_takes_the_rejecting_branch_test() {
  let report = process.new_subject()
  let started = start_haggle(100, report)

  state_machine.cast(started.ref, Offer(500))

  assert process.receive(report, within: 1000) == Ok("rejected")
  assert where(started) == WalkedAway
}

// EXHAUSTIVE BRANCHING

type Waiting =
  core.Offer(core.Done, core.Done)

fn waiting(
  channel: Channel(Waiting, Wire),
  taking: pm.Branch,
  report: Subject(String),
) -> LookupPosition(Waiting) {
  pm.state(tag: Idle, at: channel, data: Nil, handler: fn(event, channel, data) {
    case event {
      state_machine.Cast(Proceed) ->
        // Both continuations are arguments, so neither branch can be
        // forgotten. The compiler counts them.
        pm.follow(
          at: channel,
          taking: taking,
          actions: [],
          left: fn(next) {
            process.send(report, "left")
            settled(next)
          },
          right: fn(next) {
            process.send(report, "right")
            settled(next)
          },
        )
      state_machine.Call(from, WhereAreWe) ->
        pm.hold(data:, actions: [state_machine.reply(from, Idle)])
      _ -> pm.postpone()
    }
  })
}

pub fn follow_takes_the_branch_it_is_given_test() {
  let report = process.new_subject()

  let run = fn(branch) {
    let channel: Channel(Waiting, Wire) =
      core.begin(process.self(), protocol: "branch")
    let assert Ok(started) =
      pm.new(waiting(channel, branch, report)) |> pm.start_link
    state_machine.cast(started.ref, Proceed)
    let assert Ok(taken) = process.receive(report, within: 1000)
    taken
  }

  assert run(pm.Left) == "left"
  assert run(pm.Right) == "right"
}

// helpers

fn where(started: state_machine.Started(Wire)) -> Tag {
  let request: state_machine.RequestId(Tag) =
    state_machine.send_request(started.ref, WhereAreWe)
  let assert Ok(tag) = state_machine.receive_response(request, 1000)
  tag
}
