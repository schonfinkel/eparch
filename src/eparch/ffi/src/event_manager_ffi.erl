-module(event_manager_ffi).
-include("eparch_otp_features.hrl").
-moduledoc """
Erlang FFI bridge for the event_manager Gleam module.

This module serves a dual role:

  1. **API layer**: functions called from Gleam via @external(erlang, ...).
  2. **gen_event handler module**: implements the gen_event handler callbacks
     so that Gleam-defined handlers can be registered with a gen_event manager
     via `gen_event:add_handler(Mgr, {event_manager_ffi, Ref}, Args)`.

Each Gleam handler is stored in the gen_event handler state as a
`#gleam_handler{}` record.  The unique `Ref` (an Erlang reference) forms the
second element of the handler identifier `{event_manager_ffi, Ref}`, making
every installed instance distinguishable.
""".

-behaviour(gen_event).

%% Public API (called from Gleam via @external)
-export([
    do_start_link/1,
    do_start_no_link/1,
    do_start_monitor/1,
    do_stop/1,
    do_manager_pid/1,
    do_add_handler/2,
    do_add_sup_handler/2,
    do_remove_handler/2,
    do_swap_handler/3,
    do_swap_sup_handler/3,
    do_which_handlers/1,
    do_notify/2,
    do_sync_notify/2,
    send_request/3,
    receive_response/2,
    wait_response/2,
    check_response/2,
    reqids_new/0,
    reqids_add/3,
    reqids_size/1,
    reqids_to_list/1,
    send_request_to_collection/5,
    receive_response_collection/3,
    wait_response_collection/3,
    check_response_collection/3
]).

%% gen_event handler callbacks
-export([
    init/1,
    handle_event/2,
    handle_info/2,
    handle_call/2,
    terminate/2,
    code_change/3,
    format_status/1
]).

%%%===================================================================
%%% Internal handler state
%%%===================================================================
-record(gleam_handler, {
    % The unique reference part of {event_manager_ffi, Ref}
    ref,
    % User's current Gleam state value
    gleam_state,
    % fn(event, state) -> EventStep
    on_event,
    % none | {some, fn(request, state) -> {reply, new_state}}
    on_call,
    % none | {some, fn(state) -> nil}
    on_terminate,
    % none | {some, fn(state) -> binary()}
    on_format_status,
    % none | {some, fn(state) -> dynamic()}
    on_swap_out,
    % none | {some, fn(dynamic()) -> state}
    on_swap_in
}).

%%%===================================================================
%%% API
%%% called from Gleam via @external
%%%===================================================================

-doc """
Start a `gen_event` manager linked to the calling process.

The Gleam side passes an opaque `StartOptions` record, encoded at the Erlang
level as:

    {start_options, NameOpt, Timeout, HibernateAfter, DebugFlags, SpawnOpts}

`NameOpt` is `none | {some, ServerName}` where `ServerName` arrives as the
canonical gen_event tuple shape: `{local, atom()}`, `{global, atom()}`, or
`{via, atom(), term()}`. Returns a `Manager(event)` value (a Pid at the
Erlang level) on success.
""".
do_start_link({start_options, NameOpt, Timeout, HibernateAfter, DebugFlags, SpawnOpts}) ->
    ErlangOpts = build_start_opts(Timeout, HibernateAfter, DebugFlags, SpawnOpts),
    Result =
        case NameOpt of
            none ->
                gen_event:start_link(ErlangOpts);
            {some, ServerName} ->
                gen_event:start_link(ServerName, ErlangOpts)
        end,
    convert_start_result(Result).

-doc """
Start a `gen_event` manager without linking it to the calling process.

Same options encoding as `do_start_link/1`. Useful when the parent will
install its own monitor or hand the manager to a custom supervisor.
""".
do_start_no_link({start_options, NameOpt, Timeout, HibernateAfter, DebugFlags, SpawnOpts}) ->
    ErlangOpts = build_start_opts(Timeout, HibernateAfter, DebugFlags, SpawnOpts),
    Result =
        case NameOpt of
            none ->
                gen_event:start(ErlangOpts);
            {some, ServerName} ->
                gen_event:start(ServerName, ErlangOpts)
        end,
    convert_start_result(Result).

-doc """
Start a gen_event manager with an atomic monitor (OTP 23.0+).

Same options encoding as `do_start_link/1`. Returns the
`MonitoredManager(manager, monitor)` 3-tuple the Gleam compiler expects.
""".
do_start_monitor({start_options, NameOpt, Timeout, HibernateAfter, DebugFlags, SpawnOpts}) ->
    ErlangOpts = build_start_opts(Timeout, HibernateAfter, DebugFlags, SpawnOpts),
    Result =
        case NameOpt of
            none ->
                ?OTP_FEATURE(
                    "23.0",
                    gen_event,
                    start_monitor,
                    1,
                    gen_event:start_monitor(ErlangOpts)
                );
            {some, ServerName} ->
                ?OTP_FEATURE(
                    "23.0",
                    gen_event,
                    start_monitor,
                    2,
                    gen_event:start_monitor(ServerName, ErlangOpts)
                )
        end,
    convert_monitor_result(Result).

convert_start_result({ok, Pid}) ->
    {ok, Pid};
convert_start_result({error, {already_started, Pid}}) ->
    {error, {already_started, Pid}};
convert_start_result({error, Reason}) ->
    {error, {start_failed, format_reason(Reason)}}.

convert_monitor_result({ok, {Pid, MonitorRef}}) ->
    {ok, {monitored_manager, Pid, MonitorRef}};
convert_monitor_result({error, {already_started, Pid}}) ->
    {error, {already_started, Pid}};
convert_monitor_result({error, Reason}) ->
    {error, {start_failed, format_reason(Reason)}}.

build_start_opts(Timeout, HibernateAfter, DebugFlags, SpawnOpts) ->
    [
        {timeout, eparch_options_ffi:timeout_to_erlang(Timeout)},
        {hibernate_after, eparch_options_ffi:timeout_to_erlang(HibernateAfter)}
    ] ++ eparch_options_ffi:build_extra_opts(DebugFlags, SpawnOpts).

%% Render an Erlang error term as a human-readable Gleam string.
format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

-doc """
Stop the event manager, terminating it with reason `normal`.

All registered handlers have their `terminate/2` callback invoked.
""".
do_stop(Pid) ->
    gen_event:stop(Pid),
    nil.

-doc """
Return the Pid of the event manager process.

At the Erlang level `Manager(event)` is already a Pid, so this is a no-op.
""".
do_manager_pid(Pid) ->
    Pid.

-doc """
Register an unsupervised Gleam handler with the manager.

Generates a unique reference, packages the Gleam handler record into
`{event_manager_ffi, Ref}`, and calls `gen_event:add_handler/3`.
Returns `{ok, HandlerRef}` or a mapped error.
""".
do_add_handler(Pid, GleamHandler) ->
    Ref = make_ref(),
    HandlerId = {event_manager_ffi, Ref},
    case gen_event:add_handler(Pid, HandlerId, {GleamHandler, Ref}) of
        ok ->
            {ok, HandlerId};
        {'EXIT', Reason} ->
            {error, {init_failed, format_reason(Reason)}};
        {error, already_started} ->
            {error, {handler_already_exists, HandlerId}};
        {error, Reason} ->
            {error, {init_failed, format_reason(Reason)}}
    end.

-doc """
Register a supervised Gleam handler with the manager.

Like `do_add_handler/2` but uses `gen_event:add_sup_handler/3`, which links
the handler to the calling process.  If the handler is removed unexpectedly,
a `{gen_event_EXIT, HandlerId, Reason}` message is sent to the caller.
""".
do_add_sup_handler(Pid, GleamHandler) ->
    Ref = make_ref(),
    HandlerId = {event_manager_ffi, Ref},
    case gen_event:add_sup_handler(Pid, HandlerId, {GleamHandler, Ref}) of
        ok ->
            {ok, HandlerId};
        {'EXIT', Reason} ->
            {error, {init_failed, format_reason(Reason)}};
        {error, already_started} ->
            {error, {handler_already_exists, HandlerId}};
        {error, Reason} ->
            {error, {init_failed, format_reason(Reason)}}
    end.

-doc """
Remove a specific handler identified by its `HandlerRef`.

Calls `gen_event:delete_handler/3`; the handler's `terminate/2` is invoked
with reason `{stop, remove_handler}`.
""".
do_remove_handler(Pid, HandlerId) ->
    case gen_event:delete_handler(Pid, HandlerId, remove_handler) of
        {error, module_not_found} ->
            {error, {handler_not_found, HandlerId}};
        {'EXIT', Reason} ->
            {error, {remove_failed, format_reason(Reason)}};
        _TerminateResult ->
            %% Any other value is what the handler's terminate/2 returned
            %% (which we treat as a successful removal).
            {ok, nil}
    end.

-doc """
Atomically swap an installed handler for a new Gleam handler.

The old handler's `terminate(swap, State)` is invoked; its return value is
threaded into the new handler's `init({swap_init, NewHandler, NewRef}, Term)`
so optional `on_swap_out`/`on_swap_in` callbacks can transfer state.
""".
do_swap_handler(Pid, OldHandlerId, NewGleamHandler) ->
    swap_common(Pid, OldHandlerId, NewGleamHandler, fun gen_event:swap_handler/3).

-doc """
Same as `do_swap_handler/3` but uses `gen_event:swap_sup_handler/3`, linking
the new handler to the caller.
""".
do_swap_sup_handler(Pid, OldHandlerId, NewGleamHandler) ->
    swap_common(Pid, OldHandlerId, NewGleamHandler, fun gen_event:swap_sup_handler/3).

swap_common(Pid, OldHandlerId, NewGleamHandler, SwapFun) ->
    NewRef = make_ref(),
    NewHandlerId = {event_manager_ffi, NewRef},
    OldArgs = swap,
    NewArgs = {swap_init, NewGleamHandler, NewRef},
    case SwapFun(Pid, {OldHandlerId, OldArgs}, {NewHandlerId, NewArgs}) of
        ok ->
            {ok, NewHandlerId};
        {error, Reason} ->
            {error, {new_handler_init_failed, format_reason(Reason)}}
    end.

-doc """
Return the list of handler identifiers (HandlerRef values) currently
registered with the manager.

Filters to only those installed by this FFI module.
""".
do_which_handlers(Pid) ->
    Handlers = gen_event:which_handlers(Pid),
    [H || {event_manager_ffi, _} = H <- Handlers].

-doc """
Asynchronously broadcast an event to all registered handlers.

Wraps `gen_event:notify/2`.  Returns immediately.
""".
do_notify(Pid, Event) ->
    gen_event:notify(Pid, Event),
    nil.

-doc """
Synchronously broadcast an event to all registered handlers.

Wraps `gen_event:sync_notify/2`.  Blocks until every handler has processed
the event.
""".
do_sync_notify(Pid, Event) ->
    gen_event:sync_notify(Pid, Event),
    nil.

%%%===================================================================
%%% gen_event handler callbacks
%%%===================================================================

-doc """
Initialise a handler instance from the Gleam Handler builder record.

The Gleam `Handler(state, event)` opaque type is represented at the Erlang
level as a 5-tuple:

    {handler, InitState, OnEvent, OnTerminate, OnFormatStatus}

We unpack it here and store the fields alongside the unique Ref in a
`#gleam_handler{}` record.
""".
init({{handler, InitState, OnEvent, OnCall, OnTerminate, OnFormatStatus, OnSwapOut, OnSwapIn}, Ref}) ->
    State = #gleam_handler{
        ref = Ref,
        gleam_state = InitState,
        on_event = OnEvent,
        on_call = OnCall,
        on_terminate = OnTerminate,
        on_format_status = OnFormatStatus,
        on_swap_out = OnSwapOut,
        on_swap_in = OnSwapIn
    },
    {ok, State};
init({{swap_init, GleamHandler, Ref}, TermResult}) ->
    {handler, InitState, OnEvent, OnCall, OnTerminate, OnFormatStatus, OnSwapOut, OnSwapIn} =
        GleamHandler,
    FinalInitState =
        case OnSwapIn of
            none -> InitState;
            %% `SwapTerm` is an empty Gleam type with identity runtime
            %% representation, so TermResult is passed through unchanged.
            {some, F} -> F(TermResult)
        end,
    State = #gleam_handler{
        ref = Ref,
        gleam_state = FinalInitState,
        on_event = OnEvent,
        on_call = OnCall,
        on_terminate = OnTerminate,
        on_format_status = OnFormatStatus,
        on_swap_out = OnSwapOut,
        on_swap_in = OnSwapIn
    },
    {ok, State}.

-doc """
Deliver an event dispatched via `notify` or `sync_notify` to the Gleam handler.

Calls `OnEvent(Event, GleamState)` and converts the returned `EventStep`:
- `{continue, NewState}` -> `{ok, UpdatedRecord}` (keep the handler)
- `remove` -> `remove_handler`
""".
handle_event(Event, #gleam_handler{on_event = OnEvent, gleam_state = GleamState} = State) ->
    case OnEvent(Event, GleamState) of
        {continue, NewState} ->
            {ok, State#gleam_handler{gleam_state = NewState}};
        remove ->
            remove_handler
    end.

-doc """
Handle messages delivered directly to the manager's mailbox (not via
`notify`/`sync_notify`).

Uses the same `on_event` callback as `handle_event/2`.
""".
handle_info(Info, #gleam_handler{on_event = OnEvent, gleam_state = GleamState} = State) ->
    case OnEvent(Info, GleamState) of
        {continue, NewState} ->
            {ok, State#gleam_handler{gleam_state = NewState}};
        remove ->
            remove_handler
    end.

-doc """
Synchronous call to a specific handler via `gen_event:call/3,4`.

When the handler was registered with `with_call_handler`, the `on_call`
function is invoked with the request and the current Gleam state; the returned
`{Reply, NewState}` tuple is used to update the handler and reply to the
caller. Handlers without `on_call` return `{error, not_supported}`.
""".
handle_call(Request, #gleam_handler{on_call = OnCall, gleam_state = GleamState} = State) ->
    case OnCall of
        none ->
            {ok, {gleam_call_error, not_supported}, State};
        {some, F} ->
            {Reply, NewGleamState} = F(Request, GleamState),
            {ok, {gleam_call_ok, Reply}, State#gleam_handler{gleam_state = NewGleamState}}
    end.

-doc """
Handler teardown.

Calls the optional `on_terminate` Gleam function with the final state if one
was registered.
""".
terminate(swap, #gleam_handler{on_swap_out = OnSwapOut, gleam_state = GleamState}) ->
    case OnSwapOut of
        none -> nil;
        %% On the Gleam side `SwapTerm` is an empty/opaque type, so the value
        %% returned by F is already the raw term to pass forward as TermResult.
        {some, F} -> F(GleamState)
    end;
terminate(_Reason, #gleam_handler{on_terminate = OnTerminate, gleam_state = GleamState}) ->
    case OnTerminate of
        none ->
            ok;
        {some, F} ->
            F(GleamState),
            ok
    end.

-doc """
Hot-code upgrade support (pass-through).
""".
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-doc """
Format the handler state for `sys:get_status/1` and SASL crash reports.

OTP 25+ semantics: receives a status map containing `state` (the handler's
internal record) plus optional `message`, `reason`, and `log` keys. Returns
the same map, optionally with `state` replaced by the user-supplied
formatter's output. When no `on_format_status` was registered, the map is
returned unchanged.
""".
format_status(
    #{
        state := #gleam_handler{
            on_format_status = OnFormatStatus,
            gleam_state = GleamState
        }
    } = Status
) ->
    case OnFormatStatus of
        none ->
            Status;
        {some, Fun} ->
            Status#{state => Fun(GleamState)}
    end.

%%%===================================================================
%%% Async call API: native `gen_event:send_request/3` (OTP 23+),
%%% reqids collections (OTP 25+)
%%%===================================================================

-doc """
Asynchronously call a specific handler and return a `gen_event` request id.

Wraps `gen_event:send_request/3`. Use `receive_response/2`, `wait_response/2`,
or `check_response/2` to collect the reply.
""".
send_request(Manager, HandlerId, Request) ->
    ?OTP_FEATURE(
        "23.0",
        gen_event,
        send_request,
        3,
        gen_event:send_request(Manager, HandlerId, Request)
    ).

-doc """
Block up to `Timeout` milliseconds for the reply to `ReqId`.

Returns `{ok, Reply}` on success, `{error, receive_timeout}` on timeout, or
`{error, {request_crashed, StopReason}}` if the handler/manager exited before
replying. Drains the matching message from the mailbox.
""".
receive_response(ReqId, Timeout) ->
    ?OTP_FEATURE(
        "23.0",
        gen_event,
        receive_response,
        2,
        case gen_event:receive_response(ReqId, Timeout) of
            {reply, {gleam_call_ok, Reply}} ->
                {ok, Reply};
            {reply, {gleam_call_error, Reason}} ->
                {error, {request_crashed, classify_reason(Reason)}};
            timeout ->
                {error, receive_timeout};
            {error, {Reason, _Ref}} ->
                {error, {request_crashed, classify_reason(Reason)}}
        end
    ).

-doc """
Same as `receive_response/2` but leaves non-matching messages in the mailbox
on success (it does not selectively drain). Maps to `gen_event:wait_response/2`.
""".
wait_response(ReqId, Timeout) ->
    ?OTP_FEATURE(
        "23.0",
        gen_event,
        wait_response,
        2,
        case gen_event:wait_response(ReqId, Timeout) of
            {reply, {gleam_call_ok, Reply}} ->
                {ok, Reply};
            {reply, {gleam_call_error, Reason}} ->
                {error, {request_crashed, classify_reason(Reason)}};
            timeout ->
                {error, receive_timeout};
            {error, {Reason, _Ref}} ->
                {error, {request_crashed, classify_reason(Reason)}}
        end
    ).

-doc """
Non-blocking check: test whether `Msg` is a reply for `ReqId`.

Returns `{check_got_reply, Reply}`, `{check_crashed, StopReason}`, or
`check_no_reply` if the message belongs to a different request.
""".
check_response(Msg, ReqId) ->
    ?OTP_FEATURE(
        "23.0",
        gen_event,
        check_response,
        2,
        case gen_event:check_response(Msg, ReqId) of
            {reply, {gleam_call_ok, Reply}} ->
                {check_got_reply, Reply};
            {reply, {gleam_call_error, Reason}} ->
                {check_crashed, classify_reason(Reason)};
            no_reply ->
                check_no_reply;
            {error, {Reason, _Ref}} ->
                {check_crashed, classify_reason(Reason)}
        end
    ).

%%%===================================================================
%%% reqids collection API: OTP 25.0+
%%%===================================================================

-doc "Creates a new empty request-id collection.".
reqids_new() ->
    ?OTP_FEATURE("25.0", gen_event, reqids_new, 0, gen_event:reqids_new()).

-doc "Adds a request id to a collection under the given label.".
reqids_add(ReqId, Label, Collection) ->
    ?OTP_FEATURE(
        "25.0",
        gen_event,
        reqids_add,
        3,
        gen_event:reqids_add(ReqId, Label, Collection)
    ).

-doc "Returns the number of request ids in the collection.".
reqids_size(Collection) ->
    ?OTP_FEATURE("25.0", gen_event, reqids_size, 1, gen_event:reqids_size(Collection)).

-doc "Converts the collection to a list of {ReqId, Label} pairs.".
reqids_to_list(Collection) ->
    ?OTP_FEATURE(
        "25.0",
        gen_event,
        reqids_to_list,
        1,
        gen_event:reqids_to_list(Collection)
    ).

-doc """
Like `send_request/3` but also adds the resulting request id (under `Label`)
to `Collection`, returning the updated collection.
""".
send_request_to_collection(Manager, HandlerId, Request, Label, Collection) ->
    ?OTP_FEATURE(
        "25.0",
        gen_event,
        send_request,
        5,
        gen_event:send_request(Manager, HandlerId, Request, Label, Collection)
    ).

-doc """
Drain (or peek, when `Handling = keep`) the next reply from a collection.

Maps `gen_event:receive_response/3` to a Gleam `CollectionResponse`:
  `{got_reply, Reply, Label, NewColl}`
  `{request_failed, StopReason, Label, NewColl}`
  `{collection_timeout, Collection}`
  `no_requests`
""".
receive_response_collection(Collection, Timeout, Handling) ->
    Delete = (Handling =:= delete),
    ?OTP_FEATURE(
        "25.0",
        gen_event,
        receive_response,
        3,
        case gen_event:receive_response(Collection, Timeout, Delete) of
            {{reply, {gleam_call_ok, Reply}}, Label, NewColl} ->
                {got_reply, Reply, Label, NewColl};
            {{reply, {gleam_call_error, Reason}}, Label, NewColl} ->
                {request_failed, classify_reason(Reason), Label, NewColl};
            {{error, {Reason, _Ref}}, Label, NewColl} ->
                {request_failed, classify_reason(Reason), Label, NewColl};
            no_request ->
                no_requests;
            timeout ->
                {collection_timeout, Collection}
        end
    ).

-doc """
Like `receive_response_collection/3` but uses `gen_event:wait_response/3`,
which does not drain non-matching mailbox messages on success.
""".
wait_response_collection(Collection, Timeout, Handling) ->
    Delete = (Handling =:= delete),
    ?OTP_FEATURE(
        "25.0",
        gen_event,
        wait_response,
        3,
        case gen_event:wait_response(Collection, Timeout, Delete) of
            {{reply, {gleam_call_ok, Reply}}, Label, NewColl} ->
                {got_reply, Reply, Label, NewColl};
            {{reply, {gleam_call_error, Reason}}, Label, NewColl} ->
                {request_failed, classify_reason(Reason), Label, NewColl};
            {{error, {Reason, _Ref}}, Label, NewColl} ->
                {request_failed, classify_reason(Reason), Label, NewColl};
            no_request ->
                no_requests;
            timeout ->
                {collection_timeout, Collection}
        end
    ).

-doc """
Non-blocking check: test whether `Msg` is a reply for any request in
`Collection`. Maps to `gen_event:check_response/3`. Never blocks.

  `{got_reply, Reply, Label, NewColl}`: Msg is a successful reply
  `{request_failed, StopReason, Label, NewColl}`: Msg is a crash report
  `{no_reply, Collection}`: Msg is unrelated to any request in this collection
  `no_requests`: the collection was empty
""".
check_response_collection(Msg, Collection, Handling) ->
    Delete = (Handling =:= delete),
    ?OTP_FEATURE(
        "25.0",
        gen_event,
        check_response,
        3,
        case gen_event:check_response(Msg, Collection, Delete) of
            {{reply, {gleam_call_ok, Reply}}, Label, NewColl} ->
                {got_reply, Reply, Label, NewColl};
            {{reply, {gleam_call_error, Reason}}, Label, NewColl} ->
                {request_failed, classify_reason(Reason), Label, NewColl};
            {{error, {Reason, _Ref}}, Label, NewColl} ->
                {request_failed, classify_reason(Reason), Label, NewColl};
            no_reply ->
                {no_reply, Collection};
            no_request ->
                no_requests
        end
    ).

%%%===================================================================
%%% Internal helpers
%%%===================================================================

-doc """
Classify a raw Erlang exit reason as a Gleam `StopReason`. Mirrors
`statem_ffi:classify_reason/1`.
""".
classify_reason(normal) -> {exit, {normal}};
classify_reason(killed) -> {exit, {killed}};
classify_reason({abnormal, T}) -> {exit, {abnormal, T}};
classify_reason(Other) -> {raw_reason, Other}.
