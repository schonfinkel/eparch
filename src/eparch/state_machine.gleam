//// A type-safe, OTP-compatible, finite state machine implementation that
//// leverages Erlang's [gen_statem](https://www.erlang.org/doc/apps/stdlib/gen_statem.html) behavior throught the [Gleam ffi](https://gleam.run/documentation/externals/#Erlang-externals).
////
//// ## Differences from `gen_statem`
////
//// Unlike Erlang's `gen_statem`, this implementation:
//// - Uses a single `Event` type to unify calls, casts, and info messages
//// - Makes actions explicit and type-safe (no raw tuples)
//// - Makes [state_enter](https://www.erlang.org/doc/apps/stdlib/gen_statem.html#t:state_enter/0) an opt-in feature, you need to explicity set it so in the Builder.
//// - Returns strongly-typed Steps instead of various tuple formats
////

import gleam/erlang/process.{type ExitReason, type Pid, type Subject}
import gleam/option.{type Option, None, Some}

type StateEnter {
  StateEnterEnabled
  StateEnterDisabled
}

/// A builder for configuring a state machine before starting it.
///
/// Generic parameters:
/// - `state`: The type of state values (e.g., enum, custom type)
/// - `data`: The type of data carried across state transitions
/// - `msg`: The type of messages the state machine receives
/// - `return`: What the start function returns to the parent
///
pub opaque type Builder(state, data, msg, return, reply) {
  Builder(
    initial_state: state,
    initial_data: data,
    event_handler: fn(Event(state, msg, reply), state, data) ->
      Step(state, data, msg, reply),
    state_enter: StateEnter,
    initialisation_timeout: Int,
    name: Option(process.Name(msg)),
    on_code_change: Option(fn(data) -> data),
  )
}

/// Events that a state machine can receive.
///
/// This unifies the three types of messages in OTP:
/// - Calls (synchronous, requires reply)
/// - Casts (asynchronous / fire-and-forget)
/// - Info (other messages, from selectors/monitors)
///
pub type Event(state, msg, reply) {
  /// A synchronous call that expects a reply
  Call(from: From(reply), message: msg)

  /// An asynchronous cast (fire-and-forget)
  Cast(message: msg)

  /// An info message (from selectors, monitors, etc)
  Info(message: msg)

  /// Internal event fired when entering a state (if state_enter enabled)
  /// Contains the previous state
  Enter(old_state: state)

  /// Timeout events (state timeout or generic timeout)
  Timeout(timeout: TimeoutType)
}

/// The result of handling an event.
///
/// Indicates what the state machine should do next.
///
pub type Step(state, data, msg, reply) {
  /// Transition to a new state
  NextState(state: state, data: data, actions: List(Action(msg, reply)))

  /// Keep the current state
  KeepState(data: data, actions: List(Action(msg, reply)))

  /// Stop the state machine
  Stop(reason: ExitReason)
}

/// Actions (side effects) to perform after handling an event.
///
/// Multiple actions can be returned as a list.
///
pub type Action(msg, reply) {
  /// Send a reply to a caller
  Reply(from: From(reply), response: reply)

  /// Postpone this event until after a state change
  Postpone

  /// Insert a new event at the front of the queue
  NextEvent(content: msg)

  /// Set a state timeout (canceled on state change)
  StateTimeout(milliseconds: Int)

  /// Set a generic named timeout
  GenericTimeout(name: String, milliseconds: Int)
}

/// Types of timeouts
pub type TimeoutType {
  StateTimeoutType
  GenericTimeoutType(name: String)
}

/// Opaque reference to a caller (for replying to calls).
///
/// Represents Erlang's `gen_statem:from()` type. Values of this type
/// only ever originate from a `Call` event delivered by the gen_statem
/// runtime, or from `from_for_testing/0` in unit tests.
///
pub type From(reply)

/// Data returned when a state machine starts successfully.
pub type Started(data) {
  Started(
    /// The process identifier of the started state machine
    pid: Pid,
    /// Data returned after initialization (typically a Subject)
    data: data,
  )
}

/// Errors that can occur when starting a state machine.
pub type StartError {
  InitTimeout
  InitFailed(String)
  InitExited(ExitReason)
}

/// Convenience type for start results.
pub type StartResult(data) =
  Result(Started(data), StartError)

/// Create a new state machine builder with initial state and data.
///
/// By default, the state machine will return a Subject that can be used
/// to send messages to it.
///
/// ## Example
///
/// ```gleam
/// state_machine.new(initial_state: Idle, initial_data: 0)
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn new(
  initial_state initial_state: state,
  initial_data initial_data: data,
) -> Builder(state, data, msg, Subject(msg), reply) {
  Builder(
    initial_state: initial_state,
    initial_data: initial_data,
    event_handler: fn(_, _state, data) { keep_state(data, []) },
    state_enter: StateEnterDisabled,
    initialisation_timeout: 1000,
    name: None,
    on_code_change: None,
  )
}

/// Set the event handler callback function.
///
/// This function is called for every event the state machine receives.
/// It takes the current event, state, and data, and returns a Step
/// indicating what to do next.
///
/// ## Example
///
/// ```gleam
/// fn handle_event(event, state, data) {
///   case event, state {
///     Call(from, GetCount), Running ->
///       keep_state(data, [Reply(from, data.count)])
///
///     Cast(Increment), Running ->
///       keep_state(Data(..data, count: data.count + 1), [])
///
///     _, _ -> keep_state(data, [])
///   }
/// }
///
/// state_machine.new(Running, Data(0))
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn on_event(
  builder: Builder(state, data, msg, return, reply),
  handler: fn(Event(state, msg, reply), state, data) ->
    Step(state, data, msg, reply),
) -> Builder(state, data, msg, return, reply) {
  Builder(..builder, event_handler: handler)
}

/// Enable [state_enter](https://www.erlang.org/doc/apps/stdlib/gen_statem.html#t:state_enter/0) calls.
///
/// When enabled, your event handler will be called with an `Enter` event
/// whenever the state changes. This allows you to perform actions when
/// entering a state (like setting timeouts, logging, etc).
///
/// The Enter event contains the previous state.
///
/// ## Example
///
/// ```gleam
/// fn handle_event(event, state, data) {
///   case event, state {
///     Enter(old), Active if old != Active -> {
///       // Perform entry actions
///       keep_state(data, [StateTimeout(30_000)])
///     }
///     _, _ -> keep_state(data, [])
///   }
/// }
///
/// state_machine.new(Idle, data)
/// |> state_machine.with_state_enter()
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn with_state_enter(
  builder: Builder(state, data, msg, return, reply),
) -> Builder(state, data, msg, return, reply) {
  Builder(..builder, state_enter: StateEnterEnabled)
}

/// Provide a name for the state machine to be registered with when started.
///
/// This enables sending messages to it via a named subject.
///
pub fn named(
  builder: Builder(state, data, msg, return, reply),
  name: process.Name(msg),
) -> Builder(state, data, msg, return, reply) {
  Builder(..builder, name: Some(name))
}

/// Provide a migration function called during hot-code upgrades.
///
/// When an OTP release upgrades the running code, `gen_statem` calls
/// `code_change/4`. If a migration function is set, it receives the current
/// data value and its return value becomes the new data. Use this to migrate
/// data structures between versions without restarting the process.
///
/// If not set, the data passes through unchanged (the default and safe
/// behaviour for most applications).
///
/// ## Example
///
/// ```gleam
/// // Old data shape: Int
/// // New data shape: Data(count: Int, label: String)
/// state_machine.new(Idle, 0)
/// |> state_machine.on_code_change(fn(old_count) { Data(old_count, "default") })
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn on_code_change(
  builder: Builder(state, data, msg, return, reply),
  handler: fn(data) -> data,
) -> Builder(state, data, msg, return, reply) {
  Builder(..builder, on_code_change: Some(handler))
}

/// Start the state machine process.
///
/// Spawns a linked gen_statem process, runs initialisation, and returns
/// a `Started` value containing the PID and a `Subject` that can be used
/// to send messages to the machine.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(machine) =
///   state_machine.new(initial_state: Idle, initial_data: 0)
///   |> state_machine.on_event(handle_event)
///   |> state_machine.start
///
/// // Send a fire-and-forget message
/// process.send(machine.data, SomeMessage)
///
/// // Send a synchronous message with a reply
/// let reply = process.call(machine.data, 1000, SomeRequest)
/// ```
///
pub fn start(
  builder: Builder(state, data, msg, Subject(msg), reply),
) -> Result(Started(Subject(msg)), StartError) {
  let Builder(
    initial_state:,
    initial_data:,
    event_handler:,
    state_enter:,
    initialisation_timeout:,
    name:,
    on_code_change:,
  ) = builder
  do_start(
    initial_state,
    initial_data,
    event_handler,
    state_enter,
    initialisation_timeout,
    name,
    on_code_change,
  )
}

@external(erlang, "statem_ffi", "do_start")
fn do_start(
  initial_state: state,
  initial_data: data,
  event_handler: fn(Event(state, msg, reply), state, data) ->
    Step(state, data, msg, reply),
  state_enter: StateEnter,
  initialisation_timeout: Int,
  name: Option(process.Name(msg)),
  on_code_change: Option(fn(data) -> data),
) -> Result(Started(Subject(msg)), StartError)

/// Create a NextState step indicating a state transition.
///
/// ## Example
///
/// ```gleam
/// next_state(Active, new_data, [StateTimeout(5000)])
/// ```
///
pub fn next_state(
  state: state,
  data: data,
  actions: List(Action(msg, reply)),
) -> Step(state, data, msg, reply) {
  NextState(state:, data:, actions:)
}

/// Create a KeepState step indicating no state change.
///
/// ## Example
///
/// ```gleam
/// keep_state(data, [])
/// ```
///
pub fn keep_state(
  data: data,
  actions: List(Action(msg, reply)),
) -> Step(state, data, msg, reply) {
  KeepState(data:, actions:)
}

/// Create a Stop step indicating the state machine should terminate.
///
/// ## Example
///
/// ```gleam
/// stop(process.Normal)
/// ```
///
pub fn stop(reason: ExitReason) -> Step(state, data, msg, reply) {
  Stop(reason:)
}

/// Create a Reply action.
///
/// ## Example
///
/// ```gleam
/// case event {
///   Call(from, GetData) -> keep_state(data, [Reply(from, data)])
///   _ -> keep_state(data, [])
/// }
/// ```
///
pub fn reply(from: From(reply), response: reply) -> Action(msg, reply) {
  Reply(from:, response:)
}

/// Create a Postpone action.
///
/// Postpones the current event until after the next state change.
///
pub fn postpone() -> Action(msg, reply) {
  Postpone
}

/// Create a NextEvent action.
///
/// Inserts a new event at the front of the event queue.
///
pub fn next_event(content: msg) -> Action(msg, reply) {
  NextEvent(content:)
}

/// Create a StateTimeout action.
///
/// Sets a timeout that is automatically canceled when the state changes.
///
pub fn state_timeout(milliseconds: Int) -> Action(msg, reply) {
  StateTimeout(milliseconds:)
}

/// Create a GenericTimeout action.
///
/// Sets a named timeout that persists across state changes.
///
pub fn generic_timeout(name: String, milliseconds: Int) -> Action(msg, reply) {
  GenericTimeout(name:, milliseconds:)
}

/// Create a dummy `From` value for use in unit tests only.
///
/// Because `From` is an external type with no Gleam constructor, handler
/// functions cannot be called with a real `From` outside of the gen_statem
/// infrastructure. This function produces a value that lets you exercise
/// `Call` events in pure unit tests without starting an actual state machine
/// process.
///
/// In production code, `From` values always originate from a `Call` event
/// delivered by the gen_statem runtime.
///
@external(erlang, "statem_ffi", "from_for_testing")
pub fn from_for_testing() -> From(reply)

/// Reply and transition to a new state.
///
/// ## Example
///
/// ```gleam
/// reply_and_next(from, Ok(Nil), Active, new_data)
/// ```
///
pub fn reply_and_next(
  from: From(reply),
  response: reply,
  state: state,
  data: data,
) -> Step(state, data, msg, reply) {
  NextState(state:, data:, actions: [Reply(from:, response:)])
}

/// Reply and keep the current state.
///
/// ## Example
///
/// ```gleam
/// reply_and_keep(from, Ok(data.count), data)
/// ```
///
pub fn reply_and_keep(
  from: From(reply),
  response: reply,
  data: data,
) -> Step(state, data, msg, reply) {
  KeepState(data:, actions: [Reply(from:, response:)])
}

/// Send a message to a state machine via `process.send` (arrives as `Info`).
///
/// The message is delivered to the handler as `Info(msg)`. Use this for
/// messages sent from processes that are not aware of this library — e.g.
/// monitors, timers, or plain Erlang processes.
///
/// To deliver messages as `Cast(msg)` instead, use `cast/2`.
///
pub fn send(subject: Subject(msg), msg: msg) -> Nil {
  process.send(subject, msg)
}

/// Send an asynchronous cast to a state machine (arrives as `Cast`).
///
/// Unlike `send`, which routes messages through `process.send` and delivers
/// them as `Info(msg)`, this function calls `gen_statem:cast` so messages
/// arrive as `Cast(msg)` in the event handler.
///
/// Use `cast` when you want to distinguish machine-level commands from
/// ambient info messages (monitors, raw Erlang signals, etc.).
///
/// ## Example
///
/// ```gleam
/// fn handle_event(event, state, data) {
///   case event {
///     Cast(Increment) -> keep_state(data + 1, [])
///     Info(_)         -> keep_state(data, [])   // ignore ambient noise
///     _               -> keep_state(data, [])
///   }
/// }
/// ```
///
@external(erlang, "statem_ffi", "cast")
pub fn cast(subject: Subject(msg), msg: msg) -> Nil

/// Send a synchronous call and wait for a reply.
///
/// This is a re-export of `process.call` for convenience.
///
pub fn call(
  subject: Subject(message),
  waiting timeout: Int,
  sending make_message: fn(Subject(reply)) -> message,
) -> reply {
  process.call(subject, timeout, make_message)
}
