////
//// Integration tests for eparch/event_manager (gen_event wrapper).
////
//// Each section has its own event type, prefixed to avoid constructor
//// name collisions across sections.
////

import eparch/event_manager
import eparch/start_options
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "sys", "get_status")
fn sys_get_status(pid: process.Pid) -> Dynamic

// ---------------------------------------------------------------------------
// START / STOP
// ---------------------------------------------------------------------------

pub fn start_and_stop_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())
  event_manager.stop(mgr)
}

pub fn start_link_with_local_name_registers_process_test() {
  let name = process.new_name("eparch_event_manager_start_link_test_")
  let options =
    event_manager.new_start_options()
    |> event_manager.with_name(event_manager.Local(name))

  let assert Ok(mgr) = event_manager.start_link(options)

  let assert Ok(registered_pid) = process.named(name)
  registered_pid |> should.equal(event_manager.manager_pid(mgr))

  event_manager.stop(mgr)
}

pub fn start_link_already_started_returns_error_test() {
  let name = process.new_name("eparch_event_manager_start_link_dup_test_")
  let options =
    event_manager.new_start_options()
    |> event_manager.with_name(event_manager.Local(name))

  let assert Ok(mgr) = event_manager.start_link(options)
  let first_pid = event_manager.manager_pid(mgr)

  let assert Error(event_manager.AlreadyStarted(reported_pid)) =
    event_manager.start_link(options)
  reported_pid |> should.equal(first_pid)

  event_manager.stop(mgr)
}

pub fn start_unlinked_does_not_propagate_crash_test() {
  let assert Ok(mgr) = event_manager.start(event_manager.new_start_options())
  let mgr_pid = event_manager.manager_pid(mgr)

  let monitor = process.monitor(mgr_pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  // Kill the manager untrappably. With no link, the test process is
  // unaffected and continues past selector_receive.
  process.kill(mgr_pid)
  let assert Ok(_down) = process.selector_receive(selector, 1000)

  // Reaching this point proves the test process did not exit alongside the
  // manager, i.e. start/1 did not establish a link.
  process.self() |> should.not_equal(mgr_pid)
}

// ---------------------------------------------------------------------------
// NOTIFY
//
// An event sent via notify/2 reaches the handler asynchronously.
// The handler embeds a Subject in the event and replies to it.
// ---------------------------------------------------------------------------

type NotifyMsg {
  NotifyPing(reply_with: process.Subject(String))
}

pub fn notify_delivers_event_to_handler_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let handler =
    event_manager.new_handler(Nil, fn(event, state) {
      case event {
        NotifyPing(reply_with: sub) -> {
          process.send(sub, "pong")
          event_manager.Continue(state)
        }
      }
    })

  let assert Ok(_ref) = event_manager.add_handler(mgr, handler)

  let reply_sub = process.new_subject()
  event_manager.notify(mgr, NotifyPing(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// SYNC NOTIFY
//
// sync_notify/2 blocks until the handler has processed the event.
// We verify ordering: sync_notify completes before we do a second send.
// ---------------------------------------------------------------------------

type SyncMsg {
  SyncPing(reply_with: process.Subject(String))
}

pub fn sync_notify_blocks_until_handler_processes_event_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let handler =
    event_manager.new_handler(Nil, fn(event, state) {
      case event {
        SyncPing(reply_with: sub) -> {
          process.send(sub, "sync-pong")
          event_manager.Continue(state)
        }
      }
    })

  let assert Ok(_ref) = event_manager.add_handler(mgr, handler)

  let reply_sub = process.new_subject()
  event_manager.sync_notify(mgr, SyncPing(reply_with: reply_sub))

  // Because sync_notify blocked, the reply is already in the mailbox.
  let assert Ok(reply) = process.receive(reply_sub, 0)
  reply |> should.equal("sync-pong")

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// MULTIPLE HANDLERS
//
// Two independent handlers both receive the same broadcast event.
// ---------------------------------------------------------------------------

type MultiMsg {
  MultiPing(reply_with: process.Subject(String))
}

pub fn multiple_handlers_both_receive_broadcast_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let make_handler = fn(tag: String) {
    event_manager.new_handler(Nil, fn(event, state) {
      case event {
        MultiPing(reply_with: sub) -> {
          process.send(sub, tag)
          event_manager.Continue(state)
        }
      }
    })
  }

  let assert Ok(_ref1) = event_manager.add_handler(mgr, make_handler("first"))
  let assert Ok(_ref2) = event_manager.add_handler(mgr, make_handler("second"))

  let reply_sub = process.new_subject()
  event_manager.sync_notify(mgr, MultiPing(reply_with: reply_sub))

  // Both handlers replied; order depends on gen_event dispatch, so sort.
  let assert Ok(r1) = process.receive(reply_sub, 1000)
  let assert Ok(r2) = process.receive(reply_sub, 1000)

  list.sort([r1, r2], by: fn(a, b) { string.compare(a, b) })
  |> should.equal(["first", "second"])

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// HANDLER SELF-REMOVAL
//
// A handler can remove itself by returning Remove from on_event.
// After removal, which_handlers should no longer include its ref.
// ---------------------------------------------------------------------------

type RemoveSelfMsg {
  RemoveSelfNow
}

pub fn handler_removes_itself_via_remove_step_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let counter_handler =
    event_manager.new_handler(Nil, fn(event, _state) {
      case event {
        RemoveSelfNow -> event_manager.Remove
      }
    })

  let assert Ok(ref) = event_manager.add_handler(mgr, counter_handler)

  // The handler is present before removal.
  event_manager.which_handlers(mgr) |> should.equal([ref])

  // Trigger self-removal.
  event_manager.sync_notify(mgr, RemoveSelfNow)

  // After removal, which_handlers is empty.
  event_manager.which_handlers(mgr) |> should.equal([])

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// EXPLICIT REMOVE HANDLER
//
// remove_handler/2 removes a specific handler by its ref.
// ---------------------------------------------------------------------------

pub fn explicit_remove_handler_removes_by_ref_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let h =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })

  let assert Ok(ref) = event_manager.add_handler(mgr, h)
  event_manager.which_handlers(mgr) |> should.equal([ref])

  let assert Ok(Nil) = event_manager.remove_handler(mgr, ref)
  event_manager.which_handlers(mgr) |> should.equal([])

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// WHICH HANDLERS
//
// which_handlers reflects the current set of registered handlers accurately
// across add/remove operations.
// ---------------------------------------------------------------------------

pub fn which_handlers_reflects_add_and_remove_operations_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let make_h = fn() {
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })
  }

  // Empty at start.
  event_manager.which_handlers(mgr) |> should.equal([])

  let assert Ok(ref1) = event_manager.add_handler(mgr, make_h())
  event_manager.which_handlers(mgr) |> should.equal([ref1])

  let assert Ok(ref2) = event_manager.add_handler(mgr, make_h())
  let handlers_after_two = event_manager.which_handlers(mgr)
  handlers_after_two |> list.length() |> should.equal(2)
  handlers_after_two |> list.contains(ref1) |> should.equal(True)
  handlers_after_two |> list.contains(ref2) |> should.equal(True)

  let assert Ok(Nil) = event_manager.remove_handler(mgr, ref1)
  event_manager.which_handlers(mgr) |> should.equal([ref2])

  let assert Ok(Nil) = event_manager.remove_handler(mgr, ref2)
  event_manager.which_handlers(mgr) |> should.equal([])

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// ON TERMINATE
//
// The on_terminate callback is invoked when a handler is removed.
// ---------------------------------------------------------------------------

type TerminateMsg {
  TerminateNow
}

pub fn on_terminate_called_when_handler_removed_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let reply_sub = process.new_subject()

  let h =
    event_manager.new_handler(Nil, fn(event, _state) {
      case event {
        TerminateNow -> event_manager.Remove
      }
    })
    |> event_manager.on_terminate(fn(_state) {
      process.send(reply_sub, "terminated")
    })

  let assert Ok(_ref) = event_manager.add_handler(mgr, h)

  event_manager.sync_notify(mgr, TerminateNow)

  let assert Ok(msg) = process.receive(reply_sub, 1000)
  msg |> should.equal("terminated")

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// ON FORMAT STATUS
//
// When on_format_status is set, sys:get_status/1 reflects the formatted
// state. When unset, the call still succeeds (raw state passes through).
// ---------------------------------------------------------------------------

pub fn on_format_status_overrides_state_in_status_report_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let h =
    event_manager.new_handler(42, fn(_event, state) {
      event_manager.Continue(state)
    })
    |> event_manager.on_format_status(fn(n) { "FORMATTED:" <> int.to_string(n) })

  let assert Ok(_ref) = event_manager.add_handler(mgr, h)

  let status = sys_get_status(event_manager.manager_pid(mgr))
  string.inspect(status)
  |> string.contains("FORMATTED:42")
  |> should.equal(True)

  event_manager.stop(mgr)
}

pub fn handler_without_format_status_still_appears_in_status_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let h =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })

  let assert Ok(_ref) = event_manager.add_handler(mgr, h)

  // Should not crash; sys:get_status returns a non-empty term.
  let _ = sys_get_status(event_manager.manager_pid(mgr))

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// START MONITOR
//
// start_monitor/0,1,2 (OTP 23.0+) starts the manager linked to the caller
// and atomically returns a monitor. The monitor fires when the manager
// exits.
// ---------------------------------------------------------------------------

type StartMonitorMsg {
  StartMonitorPing(reply_with: process.Subject(String))
}

pub fn start_monitor_returns_manager_and_monitor_test() {
  let assert Ok(monitored) =
    event_manager.start_monitor(event_manager.new_start_options())

  let handler =
    event_manager.new_handler(Nil, fn(event, state) {
      case event {
        StartMonitorPing(reply_with: subject) -> {
          process.send(subject, "pong")
          event_manager.Continue(state)
        }
      }
    })

  let assert Ok(_ref) = event_manager.add_handler(monitored.manager, handler)

  let reply_subject = process.new_subject()
  event_manager.sync_notify(
    monitored.manager,
    StartMonitorPing(reply_with: reply_subject),
  )

  let assert Ok(reply) = process.receive(reply_subject, 1000)
  reply |> should.equal("pong")

  event_manager.stop(monitored.manager)
}

pub fn start_monitor_fires_monitor_on_stop_test() {
  let assert Ok(monitored) =
    event_manager.start_monitor(event_manager.new_start_options())

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitored.monitor, fn(down) { down })

  event_manager.stop(monitored.manager)

  let assert Ok(_down) = process.selector_receive(from: selector, within: 1000)
}

pub fn start_monitor_with_name_registers_process_test() {
  let name = process.new_name("eparch_event_manager_test_")
  let options =
    event_manager.new_start_options()
    |> event_manager.with_name(event_manager.Local(name))

  let assert Ok(monitored) = event_manager.start_monitor(options)

  let assert Ok(registered_pid) = process.named(name)
  registered_pid |> should.equal(event_manager.manager_pid(monitored.manager))

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitored.monitor, fn(down) { down })

  event_manager.stop(monitored.manager)

  let assert Ok(_down) = process.selector_receive(from: selector, within: 1000)
}

pub fn start_monitor_already_started_returns_error_test() {
  let name = process.new_name("eparch_event_manager_dup_test_")
  let options =
    event_manager.new_start_options()
    |> event_manager.with_name(event_manager.Local(name))

  let assert Ok(monitored) = event_manager.start_monitor(options)
  let first_pid = event_manager.manager_pid(monitored.manager)

  let assert Error(event_manager.AlreadyStarted(reported_pid)) =
    event_manager.start_monitor(options)
  reported_pid |> should.equal(first_pid)

  event_manager.stop(monitored.manager)
}

pub fn start_monitor_accepts_option_passthrough_test() {
  let options =
    event_manager.new_start_options()
    |> event_manager.with_timeout(start_options.Milliseconds(5000))
    |> event_manager.with_spawn_options([
      start_options.SpawnPriority(start_options.PriorityNormal),
    ])

  let assert Ok(monitored) = event_manager.start_monitor(options)

  // Consume the DOWN message produced when the manager stops so it does not
  // linger in the mailbox and interfere with later tests.
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitored.monitor, fn(down) { down })

  event_manager.stop(monitored.manager)

  let assert Ok(_down) = process.selector_receive(from: selector, within: 1000)
}

// ---------------------------------------------------------------------------
// SEND_REQUEST / ASYNC CALL (OTP 23+)
//
// send_request targets a specific handler via its HandlerRef.  The handler
// must be registered with `with_call_handler`; otherwise receive_response
// returns Error(RequestCrashed(_)).
// ---------------------------------------------------------------------------

type CallMsg {
  GetCount
  IncrCount
}

pub fn send_request_returns_reply_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let handler =
    event_manager.new_handler(0, fn(event, count) {
      case event {
        IncrCount -> event_manager.Continue(count + 1)
        _ -> event_manager.Continue(count)
      }
    })
    |> event_manager.with_call_handler(fn(request, count) {
      case request {
        GetCount -> #(count, count)
        _ -> #(count, count)
      }
    })

  let assert Ok(ref) = event_manager.add_handler(mgr, handler)

  let req: event_manager.RequestId(Int) =
    event_manager.send_request(mgr, ref, GetCount)
  let assert Ok(count) = event_manager.receive_response(req, 1000)
  count |> should.equal(0)

  event_manager.stop(mgr)
}

pub fn send_request_sees_latest_handler_state_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let handler =
    event_manager.new_handler(0, fn(event, count) {
      case event {
        IncrCount -> event_manager.Continue(count + 1)
        _ -> event_manager.Continue(count)
      }
    })
    |> event_manager.with_call_handler(fn(request, count) {
      case request {
        GetCount -> #(count, count)
        _ -> #(count, count)
      }
    })

  let assert Ok(ref) = event_manager.add_handler(mgr, handler)

  event_manager.sync_notify(mgr, IncrCount)
  event_manager.sync_notify(mgr, IncrCount)

  let req: event_manager.RequestId(Int) =
    event_manager.send_request(mgr, ref, GetCount)
  let assert Ok(count) = event_manager.receive_response(req, 1000)
  count |> should.equal(2)

  event_manager.stop(mgr)
}

pub fn wait_response_returns_same_reply_as_receive_response_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let handler =
    event_manager.new_handler(42, fn(_event, state) {
      event_manager.Continue(state)
    })
    |> event_manager.with_call_handler(fn(_request, state) { #(state, state) })

  let assert Ok(ref) = event_manager.add_handler(mgr, handler)

  let req: event_manager.RequestId(Int) =
    event_manager.send_request(mgr, ref, GetCount)
  let assert Ok(value) = event_manager.wait_response(req, 1000)
  value |> should.equal(42)

  event_manager.stop(mgr)
}

pub fn check_response_returns_check_no_reply_for_unrelated_message_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let handler =
    event_manager.new_handler(0, fn(_event, state) {
      event_manager.Continue(state)
    })
    |> event_manager.with_call_handler(fn(_req, state) { #(state, state) })

  let assert Ok(ref) = event_manager.add_handler(mgr, handler)

  let req: event_manager.RequestId(Int) =
    event_manager.send_request(mgr, ref, GetCount)

  // An unrelated dynamic value should not match.
  let unrelated = dynamic.int(42)
  event_manager.check_response(unrelated, req)
  |> should.equal(event_manager.CheckNoReply)

  // Drain the real reply so the process stays clean.
  let _ = event_manager.receive_response(req, 1000)

  event_manager.stop(mgr)
}

pub fn check_response_returns_check_got_reply_when_message_matches_test() {
  // Discard any stale messages (e.g. unconsumed DOWN messages from earlier
  // tests) so that the select_other catch-all below doesn't capture them.
  process.flush_messages()

  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let handler =
    event_manager.new_handler(7, fn(_event, state) {
      event_manager.Continue(state)
    })
    |> event_manager.with_call_handler(fn(_req, state) { #(state, state) })

  let assert Ok(ref) = event_manager.add_handler(mgr, handler)

  let req: event_manager.RequestId(Int) =
    event_manager.send_request(mgr, ref, GetCount)

  // Receive the raw reply message from the mailbox via select_other, then
  // hand it to check_response.
  let selector =
    process.new_selector()
    |> process.select_other(fn(msg) { msg })
  let assert Ok(raw) = process.selector_receive(from: selector, within: 1000)

  case event_manager.check_response(raw, req) {
    event_manager.CheckGotReply(value) -> value |> should.equal(7)
    _ -> should.fail()
  }

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// SWAP HANDLER
//
// swap_handler atomically replaces an installed handler with a new one,
// running the old handler's on_swap_out and the new handler's on_swap_in to
// transfer state across the swap.
// ---------------------------------------------------------------------------

type SwapMsg {
  SwapPing(reply_with: process.Subject(String))
}

type SwapCallMsg {
  GetSwapCount
}

pub fn swap_handler_replaces_old_with_new_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let make_handler = fn(tag: String) {
    event_manager.new_handler(Nil, fn(event, state) {
      case event {
        SwapPing(reply_with: sub) -> {
          process.send(sub, tag)
          event_manager.Continue(state)
        }
      }
    })
  }

  let assert Ok(old_ref) = event_manager.add_handler(mgr, make_handler("old"))
  let assert Ok(new_ref) =
    event_manager.swap_handler(mgr, old_ref, make_handler("new"))

  event_manager.which_handlers(mgr) |> should.equal([new_ref])

  let reply_sub = process.new_subject()
  event_manager.sync_notify(mgr, SwapPing(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("new")

  event_manager.stop(mgr)
}

pub fn swap_handler_transfers_state_via_swap_hooks_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  // Old handler holds a counter; on_swap_out emits it as a SwapTerm.
  let old_handler =
    event_manager.new_handler(0, fn(_event, count) {
      event_manager.Continue(count + 1)
    })
    |> event_manager.on_swap_out(fn(count) {
      event_manager.swap_term_from(count)
    })

  // New handler starts at -1 (so we can tell init_state from transferred
  // state); on_swap_in decodes the prior counter and uses it as its state.
  let new_handler =
    event_manager.new_handler(-1, fn(_event, count) {
      event_manager.Continue(count)
    })
    |> event_manager.on_swap_in(fn(term) {
      case event_manager.swap_term_decode(term, decode.int) {
        Ok(n) -> n
        Error(_) -> -999
      }
    })
    |> event_manager.with_call_handler(fn(_request, count) { #(count, count) })

  let assert Ok(old_ref) = event_manager.add_handler(mgr, old_handler)
  event_manager.sync_notify(mgr, SwapPing(reply_with: process.new_subject()))
  event_manager.sync_notify(mgr, SwapPing(reply_with: process.new_subject()))
  event_manager.sync_notify(mgr, SwapPing(reply_with: process.new_subject()))

  let assert Ok(new_ref) = event_manager.swap_handler(mgr, old_ref, new_handler)

  let req: event_manager.RequestId(Int) =
    event_manager.send_request(mgr, new_ref, GetSwapCount)
  let assert Ok(count) = event_manager.receive_response(req, 1000)
  count |> should.equal(3)

  event_manager.stop(mgr)
}

pub fn swap_handler_without_hooks_starts_from_init_state_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let old_handler =
    event_manager.new_handler(7, fn(_event, count) {
      event_manager.Continue(count + 1)
    })

  let new_handler =
    event_manager.new_handler(42, fn(_event, count) {
      event_manager.Continue(count)
    })
    |> event_manager.with_call_handler(fn(_request, count) { #(count, count) })

  let assert Ok(old_ref) = event_manager.add_handler(mgr, old_handler)
  let assert Ok(new_ref) = event_manager.swap_handler(mgr, old_ref, new_handler)

  let req: event_manager.RequestId(Int) =
    event_manager.send_request(mgr, new_ref, GetSwapCount)
  let assert Ok(count) = event_manager.receive_response(req, 1000)
  count |> should.equal(42)

  event_manager.stop(mgr)
}

pub fn swap_handler_skips_on_terminate_test() {
  // When a handler is swapped out, its on_terminate is NOT invoked. The
  // swap path runs on_swap_out only (or nothing if neither is set). This
  // test fails (timeout) if that contract is broken.
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let reply_sub = process.new_subject()

  let old_handler =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })
    |> event_manager.on_terminate(fn(_state) {
      process.send(reply_sub, "terminated")
    })

  let new_handler =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })

  let assert Ok(old_ref) = event_manager.add_handler(mgr, old_handler)
  let assert Ok(_new_ref) =
    event_manager.swap_handler(mgr, old_ref, new_handler)

  process.receive(reply_sub, 100)
  |> should.equal(Error(Nil))

  event_manager.stop(mgr)
}

pub fn swap_handler_with_stale_ref_still_installs_new_test() {
  // gen_event:swap_handler installs the new handler even when the old ref is
  // unknown. It just hands {error, module_not_found} to the new handler's
  // on_swap_in. This test pins that behaviour.
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let h =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })
  let assert Ok(ref) = event_manager.add_handler(mgr, h)
  let assert Ok(Nil) = event_manager.remove_handler(mgr, ref)

  let new_handler =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })

  let assert Ok(new_ref) = event_manager.swap_handler(mgr, ref, new_handler)
  event_manager.which_handlers(mgr) |> should.equal([new_ref])

  event_manager.stop(mgr)
}

pub fn swap_supervised_handler_installs_new_ref_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())

  let old_handler =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })

  let new_handler =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })

  let assert Ok(old_ref) = event_manager.add_handler(mgr, old_handler)
  let assert Ok(new_ref) =
    event_manager.swap_supervised_handler(mgr, old_ref, new_handler)

  event_manager.which_handlers(mgr) |> should.equal([new_ref])

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// REQIDS COLLECTION (OTP 25+)
//
// Fan out N async requests to one or more handlers, batch them into a
// RequestIdCollection, and drain the replies as they arrive.
// ---------------------------------------------------------------------------

type ReqMsg {
  ReqGetCount
}

fn make_count_handler(initial: Int) {
  event_manager.new_handler(initial, fn(_event, state) {
    event_manager.Continue(state)
  })
  |> event_manager.with_call_handler(fn(_req, state) { #(state, state) })
}

pub fn request_ids_new_starts_empty_test() {
  let collection: event_manager.RequestIdCollection(String, Int) =
    event_manager.request_ids_new()
  event_manager.request_ids_size(collection) |> should.equal(0)
}

pub fn request_ids_size_reflects_pending_requests_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())
  let assert Ok(ref) = event_manager.add_handler(mgr, make_count_handler(0))

  let collection: event_manager.RequestIdCollection(String, Int) =
    event_manager.request_ids_new()
  event_manager.request_ids_size(collection) |> should.equal(0)

  let collection =
    event_manager.send_request_to_collection(
      mgr,
      ref,
      ReqGetCount,
      "first",
      collection,
    )
  event_manager.request_ids_size(collection) |> should.equal(1)

  let collection =
    event_manager.send_request_to_collection(
      mgr,
      ref,
      ReqGetCount,
      "second",
      collection,
    )
  event_manager.request_ids_size(collection) |> should.equal(2)

  let assert event_manager.GotReply(_, _, collection) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )
  let assert event_manager.GotReply(_, _, collection) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )
  event_manager.request_ids_size(collection) |> should.equal(0)

  event_manager.stop(mgr)
}

pub fn receive_response_collection_drains_to_no_requests_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())
  let assert Ok(ref) = event_manager.add_handler(mgr, make_count_handler(7))

  let collection: event_manager.RequestIdCollection(String, Int) =
    event_manager.request_ids_new()
    |> fn(c) {
      event_manager.send_request_to_collection(mgr, ref, ReqGetCount, "a", c)
    }
    |> fn(c) {
      event_manager.send_request_to_collection(mgr, ref, ReqGetCount, "b", c)
    }

  let assert event_manager.GotReply(value1, _, collection) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )
  let assert event_manager.GotReply(value2, _, collection) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )
  value1 |> should.equal(7)
  value2 |> should.equal(7)

  event_manager.receive_response_collection(
    collection,
    100,
    event_manager.Delete,
  )
  |> should.equal(event_manager.NoRequests)

  event_manager.stop(mgr)
}

pub fn request_ids_to_list_contains_all_entries_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())
  let assert Ok(ref) = event_manager.add_handler(mgr, make_count_handler(0))

  let collection: event_manager.RequestIdCollection(String, Int) =
    event_manager.request_ids_new()
    |> fn(c) {
      event_manager.send_request_to_collection(mgr, ref, ReqGetCount, "x", c)
    }
    |> fn(c) {
      event_manager.send_request_to_collection(mgr, ref, ReqGetCount, "y", c)
    }

  let entries = event_manager.request_ids_to_list(collection)
  list.length(entries) |> should.equal(2)
  let labels =
    list.map(entries, fn(pair) { pair.1 }) |> list.sort(string.compare)
  labels |> should.equal(["x", "y"])

  // Drain so the manager can shut down cleanly.
  let assert event_manager.GotReply(_, _, collection) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )
  let assert event_manager.GotReply(_, _, _) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )

  event_manager.stop(mgr)
}

pub fn request_ids_add_inserts_existing_request_id_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())
  let assert Ok(ref) = event_manager.add_handler(mgr, make_count_handler(3))

  let req: event_manager.RequestId(Int) =
    event_manager.send_request(mgr, ref, ReqGetCount)

  let collection: event_manager.RequestIdCollection(Int, Int) =
    event_manager.request_ids_new()
    |> event_manager.request_ids_add(req, 1, _)

  event_manager.request_ids_size(collection) |> should.equal(1)

  let assert event_manager.GotReply(value, label, _) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )
  value |> should.equal(3)
  label |> should.equal(1)

  event_manager.stop(mgr)
}

pub fn receive_response_collection_returns_collection_timeout_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())
  // Handler whose on_call sleeps for longer than the receive timeout so the
  // collection is guaranteed to time out before the reply arrives.
  let assert Ok(ref) =
    event_manager.add_handler(
      mgr,
      event_manager.new_handler(0, fn(_event, state) {
        event_manager.Continue(state)
      })
        |> event_manager.with_call_handler(fn(_req, state) {
          process.sleep(200)
          #(state, state)
        }),
    )

  let collection: event_manager.RequestIdCollection(String, Int) =
    event_manager.request_ids_new()
    |> fn(c) {
      event_manager.send_request_to_collection(mgr, ref, ReqGetCount, "slow", c)
    }

  let assert event_manager.CollectionTimeout(_) =
    event_manager.receive_response_collection(
      collection,
      50,
      event_manager.Delete,
    )

  event_manager.stop(mgr)
}

pub fn check_response_collection_returns_no_reply_for_unrelated_message_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())
  let assert Ok(ref) = event_manager.add_handler(mgr, make_count_handler(0))

  let collection: event_manager.RequestIdCollection(String, Int) =
    event_manager.request_ids_new()
    |> fn(c) {
      event_manager.send_request_to_collection(mgr, ref, ReqGetCount, "a", c)
    }

  let assert event_manager.NoReply(_) =
    event_manager.check_response_collection(
      dynamic.int(99),
      collection,
      event_manager.Delete,
    )

  // Drain the real reply so the process stays clean.
  let assert event_manager.GotReply(_, _, _) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )

  event_manager.stop(mgr)
}

pub fn check_response_collection_returns_no_requests_for_empty_collection_test() {
  let collection: event_manager.RequestIdCollection(String, Int) =
    event_manager.request_ids_new()

  event_manager.check_response_collection(
    dynamic.int(0),
    collection,
    event_manager.Delete,
  )
  |> should.equal(event_manager.NoRequests)
}

pub fn send_request_to_collection_fans_out_to_two_handlers_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())
  let assert Ok(h1) = event_manager.add_handler(mgr, make_count_handler(10))
  let assert Ok(h2) = event_manager.add_handler(mgr, make_count_handler(20))

  let collection: event_manager.RequestIdCollection(String, Int) =
    event_manager.request_ids_new()
    |> fn(c) {
      event_manager.send_request_to_collection(mgr, h1, ReqGetCount, "h1", c)
    }
    |> fn(c) {
      event_manager.send_request_to_collection(mgr, h2, ReqGetCount, "h2", c)
    }

  let assert event_manager.GotReply(v1, l1, collection) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )
  let assert event_manager.GotReply(v2, l2, _) =
    event_manager.receive_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )

  let pairs =
    [#(l1, v1), #(l2, v2)] |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  pairs |> should.equal([#("h1", 10), #("h2", 20)])

  event_manager.stop(mgr)
}

pub fn wait_response_collection_returns_got_reply_test() {
  let assert Ok(mgr) =
    event_manager.start_link(event_manager.new_start_options())
  let assert Ok(ref) = event_manager.add_handler(mgr, make_count_handler(99))

  let collection: event_manager.RequestIdCollection(String, Int) =
    event_manager.request_ids_new()
    |> fn(c) {
      event_manager.send_request_to_collection(mgr, ref, ReqGetCount, "wait", c)
    }

  let assert event_manager.GotReply(value, label, _) =
    event_manager.wait_response_collection(
      collection,
      1000,
      event_manager.Delete,
    )
  value |> should.equal(99)
  label |> should.equal("wait")

  event_manager.stop(mgr)
}
