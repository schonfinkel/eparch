//// A type-safe, OTP-compatible event manager implementation that leverages
//// Erlang's [gen_event](https://www.erlang.org/doc/apps/stdlib/gen_event.html)
//// behaviour through the [Gleam FFI](https://gleam.run/documentation/externals/#Erlang-externals).
////
//// ## Overview
////
//// An event manager is a process that hosts any number of independent
//// **handlers**. Handlers are attached and detached at runtime. When you call
//// `notify` or `sync_notify`, every currently-registered handler receives the
//// event.
////
//// ## Example
////
//// ```gleam
//// import eparch/event_manager
//// import gleam/erlang/process
////
//// type MyEvent { LogLine(String) | Flush(process.Subject(Nil)) }
////
//// case event_manager.start_link(event_manager.new_start_options()) {
////   Ok(manager) -> {
////     let handler =
////       event_manager.new_handler(0, fn(event, count) {
////         case event {
////           LogLine(_) -> event_manager.Continue(count + 1)
////           Flush(reply) -> {
////             process.send(reply, Nil)
////             event_manager.Continue(count)
////           }
////         }
////       })
////     let _ = event_manager.add_handler(manager, handler)
////     event_manager.notify(manager, LogLine("hello"))
////     event_manager.sync_notify(manager, LogLine("world"))
////   }
////   Error(_) -> Nil
//// }
//// ```

import eparch/start_options.{
  type DebugFlag, type SpawnOption, type Timeout, Infinity,
}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type DecodeError, type Decoder}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type ExitReason, type Monitor, type Name, type Pid}
import gleam/option.{type Option, None, Some}

/// The result of a handler processing an event.
///
/// Return `Continue(new_state)` to keep the handler alive with updated state,
/// or `Remove` to unregister the handler from the manager.
///
pub type EventStep(state) {
  /// Keep the handler alive and update its state.
  Continue(state: state)

  /// Remove this handler from the event manager.
  Remove
}

/// Errors that can occur when starting an event manager.
pub type StartError {
  /// A manager with the requested registered name is already running.
  /// The field carries the Pid of the already-running manager so callers can
  /// reuse it or diagnose the conflict.
  AlreadyStarted(pid: Pid)
  /// Startup failed for another reason. `reason` is a human-readable string
  /// produced from the raw Erlang error term.
  StartFailed(reason: String)
}

/// A name under which an event manager can be registered.
///
/// Mirrors `gen_event:emgr_name/0`:
/// - `Local(name)` registers locally with `erlang:register/2` and gives back
///   a `process.Name(event)` you can turn into a `Subject(event)`.
/// - `Global(name)` registers across nodes via the `global` module.
/// - `Via(module, name)` dispatches registration through any module
///   implementing the `via` registry behaviour (e.g. `gproc`, `syn`).
///
pub type ServerName(event) {
  Local(name: Name(event))
  Global(name: Atom)
  Via(module: Atom, name: Dynamic)
}

/// Options for `start_link`, `start`, and `start_monitor`. Build a value with
/// `new_start_options()` and extend it using the `with_*` setter functions.
///
pub opaque type StartOptions(event) {
  StartOptions(
    name: Option(ServerName(event)),
    timeout: Timeout,
    hibernate_after: Timeout,
    debug: List(DebugFlag),
    spawn_options: List(SpawnOption),
  )
}

/// Data returned when a manager is started with `start_monitor`.
pub type MonitoredManager(event) {
  MonitoredManager(manager: Manager(event), monitor: Monitor)
}

/// Errors that can occur when adding a handler.
pub type AddError(request, reply) {
  /// A handler with the same identity is already registered. The field
  /// carries the `HandlerRef` that caused the collision.
  HandlerAlreadyExists(handler_ref: HandlerRef(request, reply))
  /// The handler's initialisation failed. `reason` is a human-readable
  /// string produced from the raw Erlang error term.
  InitFailed(reason: String)
}

/// Errors that can occur when removing a handler.
pub type RemoveError(request, reply) {
  /// No handler with the given ref is currently registered. The field
  /// carries the `HandlerRef` the caller supplied.
  HandlerNotFound(handler_ref: HandlerRef(request, reply))
  /// Removal failed for another reason.
  RemoveFailed(reason: String)
}

/// Errors that can occur when swapping handlers.
///
/// Note: when the supplied old `HandlerRef` is not currently registered, the
/// swap still succeeds and the new handler is installed. The new handler's
/// `on_swap_in` callback receives a `SwapTerm` wrapping the Erlang term
/// `{error, module_not_found}` so it can detect this case if needed.
pub type SwapError {
  /// The new handler's init failed (e.g. its `on_swap_in` raised) or
  /// `gen_event:swap_handler/3` returned an error term. `reason` is a
  /// human-readable string produced from the raw Erlang error term.
  NewHandlerInitFailed(reason: String)
}

/// An opaque carrier for state handed from a swapped-out handler to its
/// replacement.
///
/// Produced inside `on_swap_out` via `swap_term_from` and consumed inside
/// `on_swap_in` via `swap_term_decode`. Because the producer and consumer
/// of a swap have independent state types, the carrier is intentionally
/// untyped on the Gleam side. Decode it with the `gleam/dynamic/decode`
/// module.
///
pub type SwapTerm

/// Wrap any value as a `SwapTerm` to hand to the next handler from
/// `on_swap_out`.
///
@external(erlang, "gleam_stdlib", "identity")
pub fn swap_term_from(value: anything) -> SwapTerm

/// Decode the value carried by a `SwapTerm` using a `decode.Decoder`,
/// typically inside `on_swap_in`.
///
/// ## Example
///
/// ```gleam
/// event_manager.on_swap_in(fn(term) {
///   case event_manager.swap_term_decode(term, decode.int) {
///     Ok(n) -> n
///     Error(_) -> 0
///   }
/// })
/// ```
///
pub fn swap_term_decode(
  term: SwapTerm,
  decoder: Decoder(a),
) -> Result(a, List(DecodeError)) {
  decode.run(swap_term_as_dynamic(term), decoder)
}

@external(erlang, "gleam_stdlib", "identity")
fn swap_term_as_dynamic(term: SwapTerm) -> Dynamic

/// A builder for configuring a handler before registering it with a manager.
///
/// Create one with `new_handler/2` and optionally extend it with
/// `on_terminate/2` and `on_format_status/2`.
///
pub opaque type Handler(state, event, request, reply) {
  Handler(
    init_state: state,
    on_event: fn(event, state) -> EventStep(state),
    on_call: Option(fn(request, state) -> #(reply, state)),
    on_terminate: Option(fn(state) -> Nil),
    on_format_status: Option(fn(state) -> String),
    on_swap_out: Option(fn(state) -> SwapTerm),
    on_swap_in: Option(fn(SwapTerm) -> state),
  )
}

/// An opaque reference to a specific registered handler instance.
///
/// Values of this type are only ever produced by `add_handler` or
/// `add_supervised_handler`. Pass them to `remove_handler` to unregister a
/// specific handler, or compare them with values returned by `which_handlers`.
///
/// The phantom `request`/`reply` parameters track the call protocol of the
/// handler, so `send_request` cannot be called with a mismatched request type.
/// Handlers without a call protocol carry `Nil`/`Nil`.
///
pub type HandlerRef(request, reply)

/// An opaque reference to a running event manager process.
///
/// Values of this type are produced by `start_link` and `start` (directly)
/// and by `start_monitor` (as the `manager` field of the returned
/// `MonitoredManager`). Pass them to `notify`, `sync_notify`, `add_handler`,
/// etc.
///
pub type Manager(event)

/// Handler Builder
///
/// Create a handler with an initial state and an event callback.
///
/// The `on_event` function is called for every event delivered to this handler
/// via `notify` or `sync_notify`. It receives the event and the current state,
/// and must return either `Continue(new_state)` or `Remove`.
///
/// ## Example
///
/// ```gleam
/// let handler =
///   event_manager.new_handler(initial_state: 0, on_event: fn(event, count) {
///     case event {
///       Increment -> event_manager.Continue(count + 1)
///       Reset     -> event_manager.Continue(0)
///     }
///   })
/// ```
///
pub fn new_handler(
  initial_state: state,
  handler: fn(event, state) -> EventStep(state),
) -> Handler(state, event, Nil, Nil) {
  Handler(
    init_state: initial_state,
    on_event: handler,
    on_call: None,
    on_terminate: None,
    on_format_status: None,
    on_swap_out: None,
    on_swap_in: None,
  )
}

/// Attach a cleanup function called when the handler is removed or the manager
/// stops.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(connection, on_event)
/// |> event_manager.on_terminate(fn(connection) { db.close(connection) })
/// ```
///
pub fn on_terminate(
  handler: Handler(state, event, _, _),
  cleanup: fn(state) -> Nil,
) -> Handler(state, event, _, _) {
  Handler(..handler, on_terminate: Some(cleanup))
}

/// Provide a function to format this handler's state for OTP status reports.
///
/// When set, the returned string is used in place of the raw state in
/// `sys:get_status/1` output and SASL crash reports. Useful for hiding
/// secrets, summarising large data structures, or presenting a domain-friendly
/// view. Since OTP 25.0.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(connection, on_event)
/// |> event_manager.on_format_status(fn(connection) {
///   "Conn(id=" <> connection.id <> ")"
/// })
/// ```
///
pub fn on_format_status(
  handler: Handler(state, event, _, _),
  formatter: fn(state) -> String,
) -> Handler(state, event, _, _) {
  Handler(..handler, on_format_status: Some(formatter))
}

/// Attach a call handler to a handler, enabling async request/response via
/// `send_request`. The `on_call` function receives the request and the current
/// handler state, and must return a `#(reply, new_state)` tuple.
///
/// Without this, `send_request` calls to this handler will fail with
/// `Error(RequestCrashed(_))`.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(0, on_event)
/// |> event_manager.with_call_handler(fn(GetCount, count) { #(count, count) })
/// ```
///
pub fn with_call_handler(
  handler: Handler(state, event, _, _),
  on_call: fn(request, state) -> #(reply, state),
) -> Handler(state, event, request, reply) {
  Handler(..handler, on_call: Some(on_call))
}

/// Provide a value to hand to the next handler when this one is swapped out
/// via `swap_handler` or `swap_supervised_handler`.
///
/// The function receives the current handler state and returns a `SwapTerm`
/// (built with `swap_term_from`) that the next handler's `on_swap_in` can
/// decode. When unset, the next handler's `on_swap_in` (if any) is invoked
/// with a placeholder value.
///
/// This callback is invoked **instead of** `on_terminate` when the removal
/// happens through a swap. If you need both cleanup and state transfer in
/// the swap path, run the cleanup inline within `on_swap_out`.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(0, on_event)
/// |> event_manager.on_swap_out(fn(count) { event_manager.swap_term_from(count) })
/// ```
///
pub fn on_swap_out(
  handler: Handler(state, event, request, reply),
  extract: fn(state) -> SwapTerm,
) -> Handler(state, event, request, reply) {
  Handler(..handler, on_swap_out: Some(extract))
}

/// Derive this handler's initial state from the value produced by the
/// previous handler's `on_swap_out` during a `swap_handler` operation.
///
/// When this callback is unset, the handler's `init_state` is used as-is and
/// any value produced by the previous handler is discarded.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(0, on_event)
/// |> event_manager.on_swap_in(fn(term) {
///   case event_manager.swap_term_decode(term, decode.int) {
///     Ok(n) -> n
///     Error(_) -> 0
///   }
/// })
/// ```
///
pub fn on_swap_in(
  handler: Handler(state, event, request, reply),
  hydrate: fn(SwapTerm) -> state,
) -> Handler(state, event, request, reply) {
  Handler(..handler, on_swap_in: Some(hydrate))
}

// ---------------------------------------------------------------------------
// StartOptions builder
// ---------------------------------------------------------------------------
/// Build a fresh `StartOptions` with defaults: no registered name, `Infinity`
/// for both `timeout` and `hibernate_after`, no debug flags, no spawn options.
///
pub fn new_start_options() -> StartOptions(event) {
  StartOptions(
    name: None,
    timeout: Infinity,
    hibernate_after: Infinity,
    debug: [],
    spawn_options: [],
  )
}

/// Register the manager under a name when it starts.
///
/// Pass `Local(name)` for the common local-atom registration (the only form
/// compatible with a `process.Subject`), `Global(name)` for cluster-wide
/// registration via the `global` module, or `Via(module, term)` for a
/// custom registry such as `gproc` or `syn`.
///
pub fn with_name(
  options: StartOptions(event),
  name: ServerName(event),
) -> StartOptions(event) {
  StartOptions(..options, name: Some(name))
}

/// Set the initialisation timeout. Passed through to gen_event as the
/// `{timeout, _}` option.
///
pub fn with_timeout(
  options: StartOptions(event),
  timeout: Timeout,
) -> StartOptions(event) {
  StartOptions(..options, timeout: timeout)
}

/// Set the idle hibernation timeout. Passed through to gen_event as the
/// `{hibernate_after, _}` option.
///
pub fn with_hibernate_after(
  options: StartOptions(event),
  timeout: Timeout,
) -> StartOptions(event) {
  StartOptions(..options, hibernate_after: timeout)
}

/// Set the sys debug flags for the manager.
///
pub fn with_debug(
  options: StartOptions(event),
  flags: List(DebugFlag),
) -> StartOptions(event) {
  StartOptions(..options, debug: flags)
}

/// Set the `erlang:spawn_opt/2` options forwarded to the manager process.
///
pub fn with_spawn_options(
  options: StartOptions(event),
  spawn_options: List(SpawnOption),
) -> StartOptions(event) {
  StartOptions(..options, spawn_options: spawn_options)
}

// ---------------------------------------------------------------------------
// Manager lifecycle
// ---------------------------------------------------------------------------

/// Start an event manager process linked to the caller.
///
/// Maps to `gen_event:start_link/1,2`. Use `with_name` on the options to
/// register the manager under a `Local`, `Global`, or `Via` name; otherwise
/// the manager is started anonymously.
///
/// ## Example
///
/// ```gleam
/// case event_manager.start_link(event_manager.new_start_options()) {
///   Ok(manager) -> {
///     // ... use manager ...
///     event_manager.stop(manager)
///   }
///   Error(_) -> Nil
/// }
/// ```
///
/// ## Example: registered under a local name
///
/// ```gleam
/// let name = process.new_name("my_event_manager")
/// let options =
///   event_manager.new_start_options()
///   |> event_manager.with_name(event_manager.Local(name))
/// let assert Ok(manager) = event_manager.start_link(options)
/// ```
///
pub fn start_link(
  options: StartOptions(event),
) -> Result(Manager(event), StartError) {
  do_start_link(options)
}

@external(erlang, "event_manager_ffi", "do_start_link")
fn do_start_link(
  options: StartOptions(event),
) -> Result(Manager(event), StartError)

/// Start an event manager process without linking it to the caller.
///
/// Maps to `gen_event:start/1,2`. Useful when the parent does not want
/// link-based crash propagation, e.g. when the parent will install its own
/// monitor or hand the manager to a custom supervisor.
///
pub fn start(
  options: StartOptions(event),
) -> Result(Manager(event), StartError) {
  do_start_no_link(options)
}

@external(erlang, "event_manager_ffi", "do_start_no_link")
fn do_start_no_link(
  options: StartOptions(event),
) -> Result(Manager(event), StartError)

/// Start an event manager linked to the caller and atomically return a
/// monitor for it.
///
/// Equivalent to calling `start_link(options)` followed by
/// `process.monitor(manager_pid)`, but without the race window between the
/// two calls. The returned `MonitoredManager` carries both the `Manager` and
/// a `process.Monitor` you can select on. Since OTP 23.0.
///
/// ## Example
///
/// ```gleam
/// case event_manager.start_monitor(event_manager.new_start_options()) {
///   Ok(monitored) -> {
///     let selector =
///       process.new_selector()
///       |> process.select_specific_monitor(monitored.monitor, fn(down) { down })
///     // ... use monitored.manager, wait on `selector` for a Down message ...
///   }
///   Error(_) -> Nil
/// }
/// ```
///
pub fn start_monitor(
  options: StartOptions(event),
) -> Result(MonitoredManager(event), StartError) {
  do_start_monitor(options)
}

@external(erlang, "event_manager_ffi", "do_start_monitor")
fn do_start_monitor(
  options: StartOptions(event),
) -> Result(MonitoredManager(event), StartError)

/// Stop the event manager, terminating it with reason `normal`.
///
/// All registered handlers have their `on_terminate` callback invoked before
/// the manager shuts down.
///
pub fn stop(manager: Manager(event)) -> Nil {
  do_stop(manager)
}

@external(erlang, "event_manager_ffi", "do_stop")
fn do_stop(manager: Manager(event)) -> Nil

/// Return the Pid of the event manager process.
///
/// Useful for monitoring the manager with `process.monitor` when you did not
/// start it via `start_monitor`.
///
pub fn manager_pid(manager: Manager(event)) -> Pid {
  do_manager_pid(manager)
}

@external(erlang, "event_manager_ffi", "do_manager_pid")
fn do_manager_pid(manager: Manager(event)) -> Pid

// ---------------------------------------------------------------------------
// Handler management
// ---------------------------------------------------------------------------

/// Register an unsupervised handler with the event manager.
///
/// Returns `Ok(HandlerRef)` on success. The returned ref uniquely identifies
/// this handler instance and can be used with `remove_handler`.
///
/// If the handler crashes, the manager removes it silently without notifying
/// the caller. For crash notifications use `add_supervised_handler`.
///
/// ## Example
///
/// ```gleam
/// case event_manager.add_handler(manager, my_handler) {
///   Ok(handler_ref) -> // use handler_ref later with remove_handler
///   Error(_) -> Nil
/// }
/// ```
///
pub fn add_handler(
  manager: Manager(event),
  handler: Handler(state, event, request, reply),
) -> Result(HandlerRef(request, reply), AddError(request, reply)) {
  do_add_handler(manager, handler)
}

@external(erlang, "event_manager_ffi", "do_add_handler")
fn do_add_handler(
  manager: Manager(event),
  handler: Handler(state, event, request, reply),
) -> Result(HandlerRef(request, reply), AddError(request, reply))

/// Register a supervised handler with the event manager.
///
/// Like `add_handler`, but links the handler to the calling process. If the
/// handler is removed for any reason other than a normal `remove_handler` call
/// (e.g. it crashes or returns `Remove`), the calling process receives an
/// Erlang message shaped like:
///
/// ```
/// {gen_event_EXIT, HandlerRef, Reason}
/// ```
///
/// Receive it via `gleam/erlang/process` selectors. `process.select_other` is
/// the catch-all hook you can use to observe raw Erlang messages.
///
pub fn add_supervised_handler(
  manager: Manager(event),
  handler: Handler(state, event, request, reply),
) -> Result(HandlerRef(request, reply), AddError(request, reply)) {
  do_add_supervised_handler(manager, handler)
}

@external(erlang, "event_manager_ffi", "do_add_sup_handler")
fn do_add_supervised_handler(
  manager: Manager(event),
  handler: Handler(state, event, request, reply),
) -> Result(HandlerRef(request, reply), AddError(request, reply))

/// Remove a specific handler from the event manager.
///
/// The handler's `on_terminate` callback is called before removal.
///
pub fn remove_handler(
  manager: Manager(event),
  handler_ref: HandlerRef(request, reply),
) -> Result(Nil, RemoveError(request, reply)) {
  do_remove_handler(manager, handler_ref)
}

@external(erlang, "event_manager_ffi", "do_remove_handler")
fn do_remove_handler(
  manager: Manager(event),
  handler_ref: HandlerRef(request, reply),
) -> Result(Nil, RemoveError(request, reply))

/// Atomically swap an installed handler for a new one.
///
/// Maps to `gen_event:swap_handler/3`. The old handler's `on_swap_out`
/// callback runs (if set), its result is threaded into the new handler's
/// `on_swap_in` (if set) to produce the new handler's initial state, and the
/// new handler is installed, all observed by the manager as a single
/// transaction so no `notify` can slip between the remove and the add.
///
/// On success, returns the new handler's `HandlerRef`. The old `HandlerRef`
/// becomes invalid.
///
/// The new handler is unsupervised. Use `swap_supervised_handler` to link
/// the new handler to the calling process.
///
/// ## Example
///
/// ```gleam
/// case event_manager.swap_handler(mgr, old_ref, new_handler) {
///   Ok(new_ref) -> // use new_ref
///   Error(_) -> Nil
/// }
/// ```
///
pub fn swap_handler(
  manager: Manager(event),
  old_handler_ref: HandlerRef(old_request, old_reply),
  new_handler: Handler(state, event, request, reply),
) -> Result(HandlerRef(request, reply), SwapError) {
  do_swap_handler(manager, old_handler_ref, new_handler)
}

@external(erlang, "event_manager_ffi", "do_swap_handler")
fn do_swap_handler(
  manager: Manager(event),
  old_handler_ref: HandlerRef(old_request, old_reply),
  new_handler: Handler(state, event, request, reply),
) -> Result(HandlerRef(request, reply), SwapError)

/// Atomically swap an installed handler for a new supervised handler.
///
/// Like `swap_handler`, but maps to `gen_event:swap_sup_handler/3`: the new
/// handler is linked to the calling process. If the new handler is later
/// removed for any reason other than a normal `remove_handler` call, the
/// caller receives a `{gen_event_EXIT, HandlerRef, Reason}` message.
///
pub fn swap_supervised_handler(
  manager: Manager(event),
  old_handler_ref: HandlerRef(old_request, old_reply),
  new_handler: Handler(state, event, request, reply),
) -> Result(HandlerRef(request, reply), SwapError) {
  do_swap_sup_handler(manager, old_handler_ref, new_handler)
}

@external(erlang, "event_manager_ffi", "do_swap_sup_handler")
fn do_swap_sup_handler(
  manager: Manager(event),
  old_handler_ref: HandlerRef(old_request, old_reply),
  new_handler: Handler(state, event, request, reply),
) -> Result(HandlerRef(request, reply), SwapError)

/// Return the list of `HandlerRef`s for all currently registered handlers.
///
pub fn which_handlers(
  manager: Manager(event),
) -> List(HandlerRef(request, reply)) {
  do_which_handlers(manager)
}

@external(erlang, "event_manager_ffi", "do_which_handlers")
fn do_which_handlers(
  manager: Manager(event),
) -> List(HandlerRef(request, reply))

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

/// Asynchronously broadcast an event to all registered handlers.
///
/// Returns immediately without waiting for handlers to finish processing.
/// Use `sync_notify` if you need a synchronization point.
///
pub fn notify(manager: Manager(event), event: event) -> Nil {
  do_notify(manager, event)
}

@external(erlang, "event_manager_ffi", "do_notify")
fn do_notify(manager: Manager(event), event: event) -> Nil

/// Synchronously broadcast an event to all registered handlers.
///
/// Blocks until every currently registered handler has processed the event.
/// Use this when you need to know that all handlers have seen the event before
/// continuing.
///
pub fn sync_notify(manager: Manager(event), event: event) -> Nil {
  do_sync_notify(manager, event)
}

@external(erlang, "event_manager_ffi", "do_sync_notify")
fn do_sync_notify(manager: Manager(event), event: event) -> Nil

// ---------------------------------------------------------------------------
// Async call API (OTP 23+)
// ---------------------------------------------------------------------------

/// An opaque handle for a pending async call issued by `send_request`.
///
/// The phantom type `reply` tracks the expected response type at compile time.
///
pub type RequestId(reply)

/// Termination reason classified by the FFI.
///
/// `Exit` wraps a recognised `process.ExitReason`. `RawReason` is a fallback
/// for shapes the FFI cannot classify (e.g. `{shutdown, _}`, `{noproc, _}`,
/// arbitrary user terms) so callers can still inspect the original term.
///
pub type StopReason {
  Exit(reason: ExitReason)
  RawReason(term: Dynamic)
}

/// Errors that `receive_response` and `wait_response` can return.
///
pub type ReceiveError {
  /// No reply arrived within the timeout.
  ReceiveTimeout
  /// The manager (or handler) exited before replying.
  RequestCrashed(reason: StopReason)
}

/// The result of a non-blocking `check_response` call.
///
pub type CheckResponse(reply) {
  /// A reply for the given `RequestId` was found in the mailbox.
  CheckGotReply(reply: reply)
  /// The message was not a reply for this `RequestId`.
  CheckNoReply
  /// The manager (or handler) exited before replying.
  CheckCrashed(reason: StopReason)
}

/// A collection of in-flight request IDs, each associated with a `label`.
///
/// Used with `send_request_to_collection`, `request_ids_add`, and
/// `receive_response_collection` to manage multiple concurrent requests.
/// Requires Erlang/OTP 25.0 or later.
///
pub type RequestIdCollection(label, reply)

/// Whether `receive_response_collection` (and friends) removes the matched
/// request from the returned collection after delivering the reply.
///
pub type ResponseHandling {
  Delete
  Keep
}

/// The result of waiting for, or checking for, a response from a
/// `RequestIdCollection`.
///
pub type CollectionResponse(reply, label) {
  /// A successful reply was received for one of the pending requests.
  GotReply(
    reply: reply,
    label: label,
    remaining: RequestIdCollection(label, reply),
  )

  /// One of the requests returned an error (e.g. the handler crashed).
  RequestFailed(
    reason: StopReason,
    label: label,
    remaining: RequestIdCollection(label, reply),
  )

  /// `receive_response_collection` / `wait_response_collection` only:
  /// the timeout elapsed before any pending reply arrived. The collection
  /// is unchanged.
  CollectionTimeout(remaining: RequestIdCollection(label, reply))

  /// `check_response_collection` only: the supplied message was not a
  /// reply for any request in this collection. The collection is unchanged.
  NoReply(remaining: RequestIdCollection(label, reply))

  /// The collection had no pending requests.
  NoRequests
}

/// Asynchronously call a specific handler and return a `RequestId`.
///
/// Unlike `sync_notify`, this targets one handler by its `HandlerRef` and
/// expects a reply. The handler must have been registered with
/// `with_call_handler` set; otherwise `receive_response` will return
/// `Error(RequestCrashed(_))`.
///
/// Use `receive_response` or `wait_response` to collect the reply later, or
/// `check_response` to poll non-blockingly.
///
/// ## Example
///
/// ```gleam
/// let req: event_manager.RequestId(Int) =
///   event_manager.send_request(mgr, handler_ref, GetCount)
/// // ... do other work ...
/// let assert Ok(count) = event_manager.receive_response(req, 1000)
/// ```
///
@external(erlang, "event_manager_ffi", "send_request")
pub fn send_request(
  manager: Manager(event),
  handler_ref: HandlerRef(request, reply),
  request: request,
) -> RequestId(reply)

/// Wait up to `timeout` milliseconds for the reply to a `RequestId`.
///
/// Returns `Ok(reply)` on success, `Error(ReceiveTimeout)` if no reply
/// arrives in time, or `Error(RequestCrashed(reason))` if the manager exited.
///
@external(erlang, "event_manager_ffi", "receive_response")
pub fn receive_response(
  request_id: RequestId(reply),
  timeout: Int,
) -> Result(reply, ReceiveError)

/// Wait up to `timeout` milliseconds for the reply to a `RequestId`.
///
/// Like `receive_response`, but maps to `gen_event:wait_response/2`. The two
/// differ only in mailbox semantics: `wait_response` leaves non-matching
/// messages in place on success, whereas `receive_response` selectively
/// drains the matching message (and may leave the receive buffer in a state
/// that affects later `receive` clauses).
///
@external(erlang, "event_manager_ffi", "wait_response")
pub fn wait_response(
  request_id: RequestId(reply),
  timeout: Int,
) -> Result(reply, ReceiveError)

/// Non-blocking check: inspect `message` to see if it is a reply for
/// `request_id`.
///
/// Useful inside a custom `process.Selector` receive loop. Pass any message
/// you receive; if it does not belong to this request `CheckNoReply` is
/// returned and the message is left for other handlers.
///
/// ## Example
///
/// ```gleam
/// case event_manager.check_response(raw_msg, req) {
///   event_manager.CheckGotReply(value) -> // handle value
///   event_manager.CheckNoReply -> // not ours, pass it on
///   event_manager.CheckCrashed(reason) -> // handle error
/// }
/// ```
///
@external(erlang, "event_manager_ffi", "check_response")
pub fn check_response(
  message: Dynamic,
  request_id: RequestId(reply),
) -> CheckResponse(reply)

// ---------------------------------------------------------------------------
// reqids collection API (OTP 25+)
//
// Mirrors the gen_event reqids API for fanning out multiple async requests
// and draining their replies as they arrive, each tagged with a caller-
// chosen `label`. Wraps `gen_event:reqids_*`, `gen_event:send_request/5`,
// and the 3-arity collection variants of `wait_response`/`receive_response`/
// `check_response`.
// ---------------------------------------------------------------------------

/// Create a new, empty request-id collection.
///
/// Used with `send_request_to_collection` to batch multiple async requests
/// and then drain them through `receive_response_collection` (or similar).
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "event_manager_ffi", "reqids_new")
pub fn request_ids_new() -> RequestIdCollection(label, reply)

/// Add a `RequestId` to a collection under a `label`.
///
/// The label is returned alongside the reply in
/// `receive_response_collection`, letting you identify which request the
/// response belongs to.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "event_manager_ffi", "reqids_add")
pub fn request_ids_add(
  request_id request_id: RequestId(reply),
  label label: label,
  to collection: RequestIdCollection(label, reply),
) -> RequestIdCollection(label, reply)

/// Return the number of pending request IDs in a collection.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "event_manager_ffi", "reqids_size")
pub fn request_ids_size(collection: RequestIdCollection(label, reply)) -> Int

/// Convert a collection to a list of `#(RequestId, label)` pairs.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "event_manager_ffi", "reqids_to_list")
pub fn request_ids_to_list(
  collection: RequestIdCollection(label, reply),
) -> List(#(RequestId(reply), label))

/// Send an asynchronous call to a specific handler and immediately add the
/// resulting `RequestId` to a collection under the given `label`.
///
/// Equivalent to calling `send_request` and `request_ids_add` in one step.
/// Useful for issuing several requests in a loop before waiting for any of
/// them.
///
/// ## Example
///
/// ```gleam
/// let collection: event_manager.RequestIdCollection(String, Int) =
///   event_manager.request_ids_new()
/// let collection =
///   event_manager.send_request_to_collection(mgr, h1, GetCount, "h1", collection)
/// let collection =
///   event_manager.send_request_to_collection(mgr, h2, GetCount, "h2", collection)
/// // ... drain via receive_response_collection ...
/// ```
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "event_manager_ffi", "send_request_to_collection")
pub fn send_request_to_collection(
  manager: Manager(event),
  handler_ref: HandlerRef(request, reply),
  request: request,
  label: label,
  to collection: RequestIdCollection(label, reply),
) -> RequestIdCollection(label, reply)

/// Wait up to `timeout` milliseconds for any pending reply in a collection.
///
/// Pass `Delete` to remove the matched request from the returned collection,
/// or `Keep` to retain it. Call this in a loop to drain all responses one by
/// one. Returns `CollectionTimeout(remaining)` when the timer expires before
/// any reply arrives, and `NoRequests` when the collection is empty.
///
/// Selectively drains the matched message from the mailbox; non-matching
/// mailbox messages may also be consumed.
///
/// ## Example
///
/// ```gleam
/// let assert event_manager.GotReply(value, label, collection) =
///   event_manager.receive_response_collection(
///     collection,
///     1000,
///     event_manager.Delete,
///   )
/// ```
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "event_manager_ffi", "receive_response_collection")
pub fn receive_response_collection(
  collection: RequestIdCollection(label, reply),
  timeout: Int,
  handling: ResponseHandling,
) -> CollectionResponse(reply, label)

/// Like `receive_response_collection` but maps to `gen_event:wait_response/3`.
///
/// On success, leaves non-matching mailbox messages in place rather than
/// draining them. Use when integrating with a custom `process.Selector`
/// that expects untouched non-matching messages.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "event_manager_ffi", "wait_response_collection")
pub fn wait_response_collection(
  collection: RequestIdCollection(label, reply),
  timeout: Int,
  handling: ResponseHandling,
) -> CollectionResponse(reply, label)

/// Non-blocking check: inspect `message` to see whether it is a reply for any
/// request in `collection`.
///
/// Returns `GotReply(...)` / `RequestFailed(...)` if the message belongs to
/// the collection, `NoReply(remaining)` if it is unrelated, or `NoRequests`
/// if the collection is empty. Never blocks.
///
/// ## Example
///
/// ```gleam
/// case event_manager.check_response_collection(raw_msg, coll, event_manager.Delete) {
///   event_manager.GotReply(value, label, rest) -> // handle and continue
///   event_manager.NoReply(_) -> // not ours, pass it on
///   _ -> // ...
/// }
/// ```
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "event_manager_ffi", "check_response_collection")
pub fn check_response_collection(
  message: Dynamic,
  collection: RequestIdCollection(label, reply),
  handling: ResponseHandling,
) -> CollectionResponse(reply, label)
