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
//// let assert Ok(mgr) = event_manager.start()
////
//// let handler =
////   event_manager.new_handler(0, fn(event, count) {
////     case event {
////       LogLine(_) -> event_manager.Continue(count + 1)
////       Flush(reply) -> {
////         process.send(reply, Nil)
////         event_manager.Continue(count)
////       }
////     }
////   })
////
//// let assert Ok(_ref) = event_manager.add_handler(mgr, handler)
////
//// event_manager.notify(mgr, LogLine("hello"))
//// event_manager.sync_notify(mgr, LogLine("world"))
//// ```

import gleam/erlang/process.{type Pid}
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

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
  AlreadyStarted
  StartFailed(String)
}

/// Errors that can occur when adding a handler.
pub type AddError {
  HandlerAlreadyExists
  InitFailed(String)
}

/// Errors that can occur when removing a handler.
pub type RemoveError {
  HandlerNotFound
  RemoveFailed(String)
}

/// A builder for configuring a handler before registering it with a manager.
///
/// Create one with `new_handler/2` and optionally extend it with
/// `on_terminate/2`.
///
pub opaque type Handler(state, event) {
  Handler(
    init_state: state,
    on_event: fn(event, state) -> EventStep(state),
    on_terminate: Option(fn(state) -> Nil),
  )
}

/// An opaque reference to a specific registered handler instance.
///
/// Values of this type are only ever produced by `add_handler` or
/// `add_sup_handler`. Pass them to `remove_handler` to unregister a specific
/// handler, or compare them with values returned by `which_handlers`.
///
pub type HandlerRef

/// An opaque reference to a running event manager process.
///
/// Values of this type are only ever produced by `start`. Pass them to
/// `notify`, `sync_notify`, `add_handler`, etc.
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
  initial_state initial_state: state,
  on_event handler: fn(event, state) -> EventStep(state),
) -> Handler(state, event) {
  Handler(init_state: initial_state, on_event: handler, on_terminate: None)
}

/// Attach a cleanup function called when the handler is removed or the manager
/// stops.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(conn, on_event)
/// |> event_manager.on_terminate(fn(conn) { db.close(conn) })
/// ```
///
pub fn on_terminate(
  handler: Handler(state, event),
  cleanup: fn(state) -> Nil,
) -> Handler(state, event) {
  Handler(..handler, on_terminate: Some(cleanup))
}

// Manager lifecycle
/// Start an event manager process linked to the caller.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(mgr) = event_manager.start()
/// ```
///
pub fn start() -> Result(Manager(event), StartError) {
  do_start()
}

@external(erlang, "event_manager_ffi", "do_start")
fn do_start() -> Result(Manager(event), StartError)

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
/// Useful for monitoring the manager with `process.monitor`.
///
pub fn manager_pid(manager: Manager(event)) -> Pid {
  do_manager_pid(manager)
}

@external(erlang, "event_manager_ffi", "do_manager_pid")
fn do_manager_pid(manager: Manager(event)) -> Pid

// Handler management
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
/// let assert Ok(ref) = event_manager.add_handler(mgr, my_handler)
/// ```
///
pub fn add_handler(
  manager: Manager(event),
  handler: Handler(state, event),
) -> Result(HandlerRef, AddError) {
  do_add_handler(manager, handler)
}

@external(erlang, "event_manager_ffi", "do_add_handler")
fn do_add_handler(
  manager: Manager(event),
  handler: Handler(state, event),
) -> Result(HandlerRef, AddError)

/// Register a supervised handler with the event manager.
///
/// Like `add_handler`, but links the handler to the calling process. If the
/// handler is removed for any reason other than a normal `remove_handler` call
/// (e.g. it crashes or returns `Remove`), the calling process receives a
/// message of the form:
///
/// ```
/// {gen_event_EXIT, HandlerRef, Reason}
/// ```
///
/// You can receive this message using `process.selecting_anything` with a
/// `gleam/dynamic` decoder.
///
pub fn add_supervised_handler(
  manager: Manager(event),
  handler: Handler(state, event),
) -> Result(HandlerRef, AddError) {
  do_add_supervised_handler(manager, handler)
}

@external(erlang, "event_manager_ffi", "do_add_sup_handler")
fn do_add_supervised_handler(
  manager: Manager(event),
  handler: Handler(state, event),
) -> Result(HandlerRef, AddError)

/// Remove a specific handler from the event manager.
///
/// The handler's `on_terminate` callback is called before removal.
///
pub fn remove_handler(
  manager: Manager(event),
  ref: HandlerRef,
) -> Result(Nil, RemoveError) {
  do_remove_handler(manager, ref)
}

@external(erlang, "event_manager_ffi", "do_remove_handler")
fn do_remove_handler(
  manager: Manager(event),
  ref: HandlerRef,
) -> Result(Nil, RemoveError)

/// Return the list of `HandlerRef`s for all currently registered handlers.
///
pub fn which_handlers(manager: Manager(event)) -> List(HandlerRef) {
  do_which_handlers(manager)
}

@external(erlang, "event_manager_ffi", "do_which_handlers")
fn do_which_handlers(manager: Manager(event)) -> List(HandlerRef)

// Notifications
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
