-module(statem_ffi).
-moduledoc """
Erlang FFI bridge for the statem Gleam module. Translates between Erlang's
gen_statem behavior callbacks and Gleam's type-safe API.
""".

-behaviour(gen_statem).

%% Public API
-export([
    do_start/2,
    do_start_monitor/1,
    cast/2,
    ref_to_subject/1,
    ref_from_subject/1,
    ref_from_pid/1
]).
-export([
    stop_server/1,
    stop_server_with/3,
    send_reply/2,
    send_replies/1,
    wait_response/1,
    wait_response_timeout/2,
    check_response/2,
    receive_response_blocking/1
]).
-export([
    reqids_new/0,
    reqids_add/3,
    reqids_size/1,
    reqids_to_list/1,
    send_request/2,
    send_request_to_collection/4,
    receive_response/2,
    receive_response_collection/3
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    handle_event/4,
    terminate/3,
    code_change/4,
    format_status/1
]).

%%%===================================================================
%%% Internal State Records & Types
%%%===================================================================
%% Gleam-side `ServerName(message)` ADT, encoded as the same tuple shape
%% gen_statem expects, so the value can be passed straight to OTP.
-type server_name_option() ::
    none
    | {some,
        {local, atom()}
        | {global, atom()}
        | {via, atom(), term()}}.

-record(gleam_statem, {
    % Current Gleam state value
    gleam_state,
    % Current Gleam data value
    gleam_data,
    % fn(Event, State, Data) -> Step
    gleam_handler,
    % Whether `StateEnter` events reach the Gleam handler
    state_enter,
    % The tag used in this process's Subject:
    % - unnamed: reference (make_ref())
    % - named: atom (the registered name)
    subject_tag,
    % none | {some, fn(data) -> data}
    on_code_change,
    % none | {some, fn(Status) -> Status}
    on_format_status
}).

%%%===================================================================
%%% API
%%% called from Gleam via @external
%%%===================================================================
-doc """
Start a `gen_statem` process either linked (`link`) or unlinked (`no_link`).

The Gleam side passes a `LinkMode` selector and the opaque `Builder` record;
the latter is encoded at the Erlang level as the 12-tuple defined in
`eparch/state_machine`. Returns the Gleam `Started(message)` 3-tuple
`{started, Pid, ServerRef}` or a mapped error.
""".
-spec do_start(LinkMode, Builder) -> Result when
    LinkMode :: link | no_link,
    Builder :: tuple(),
    Result :: any().
do_start(LinkMode, Builder) ->
    {AckTag, InitArgs, ExtraOpts, NameOpt} = unpack_builder(Builder),
    StartResult = invoke_start(LinkMode, NameOpt, InitArgs, ExtraOpts),
    handle_start_result(StartResult, AckTag).

-doc """
Start a `gen_statem` process linked to the caller with an atomic monitor
(OTP 23.0+). Returns the Gleam `MonitoredMachine(message)` 4-tuple
`{monitored_machine, Pid, ServerRef, MonitorRef}` or a mapped error.
""".
-spec do_start_monitor(Builder) -> Result when
    Builder :: tuple(),
    Result :: any().
do_start_monitor(Builder) ->
    {AckTag, InitArgs, ExtraOpts, NameOpt} = unpack_builder(Builder),
    StartResult = invoke_start(atomic_monitor, NameOpt, InitArgs, ExtraOpts),
    handle_monitor_start_result(StartResult, AckTag).

%% --- builder unpacking ----------------------------------------------------

-spec unpack_builder(tuple()) -> {reference(), tuple(), [term()], server_name_option()}.
unpack_builder(Builder) ->
    {builder, InitialState, InitialData, Handler, StateEnter, Timeout, HibernateAfter, Debug,
        SpawnOpts, NameOpt, OnCodeChange, OnFormatStatus} = Builder,
    AckTag = make_ref(),
    Parent = self(),
    InitArgs =
        {init_args, InitialState, InitialData, Handler, StateEnter, Parent, AckTag, NameOpt,
            OnCodeChange, OnFormatStatus},
    ExtraOpts =
        [
            {timeout, eparch_options_ffi:timeout_to_erlang(Timeout)},
            {hibernate_after, eparch_options_ffi:timeout_to_erlang(HibernateAfter)}
        ] ++ eparch_options_ffi:build_extra_opts(Debug, SpawnOpts),
    {AckTag, InitArgs, ExtraOpts, NameOpt}.

-spec invoke_start(link | no_link | atomic_monitor, server_name_option(), tuple(), [term()]) ->
    {ok, pid()} | {ok, {pid(), reference()}} | {error, term()}.
invoke_start(link, none, InitArgs, Opts) ->
    gen_statem:start_link(?MODULE, InitArgs, Opts);
invoke_start(link, {some, ServerName}, InitArgs, Opts) ->
    gen_statem:start_link(ServerName, ?MODULE, InitArgs, Opts);
invoke_start(no_link, none, InitArgs, Opts) ->
    gen_statem:start(?MODULE, InitArgs, Opts);
invoke_start(no_link, {some, ServerName}, InitArgs, Opts) ->
    gen_statem:start(ServerName, ?MODULE, InitArgs, Opts);
invoke_start(atomic_monitor, none, InitArgs, Opts) ->
    gen_statem:start_monitor(?MODULE, InitArgs, Opts);
invoke_start(atomic_monitor, {some, ServerName}, InitArgs, Opts) ->
    gen_statem:start_monitor(ServerName, ?MODULE, InitArgs, Opts).

handle_start_result({ok, Pid}, AckTag) when is_pid(Pid) ->
    case await_init_ack(AckTag) of
        {ok, ServerRef} -> {ok, {started, Pid, ServerRef}};
        Error -> Error
    end;
handle_start_result(Error, _AckTag) ->
    classify_start_error(Error).

handle_monitor_start_result({ok, {Pid, MonRef}}, AckTag) when is_pid(Pid) ->
    case await_init_ack(AckTag) of
        {ok, ServerRef} -> {ok, {monitored_machine, Pid, ServerRef, MonRef}};
        Error -> Error
    end;
handle_monitor_start_result(Error, _AckTag) ->
    classify_start_error(Error).

await_init_ack(AckTag) ->
    %% init/1 runs synchronously inside start_link/start/start_monitor, so
    %% the ServerRef is already in our mailbox by the time we get here.
    receive
        {AckTag, ServerRef} -> {ok, ServerRef}
    after 0 ->
        {error, {init_failed, <<"init/1 did not deliver a ServerRef">>}}
    end.

classify_start_error({error, timeout}) ->
    {error, init_timeout};
classify_start_error({error, {already_started, OtherPid}}) when is_pid(OtherPid) ->
    {error, {already_started, OtherPid}};
classify_start_error({error, Reason}) ->
    {error, {init_exited, {abnormal, Reason}}}.

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================
-doc """
Initialise the gen_statem process.

Creates the Subject for this process and sends it back to the parent
through the ack channel before returning to gen_statem.
""".
init(
    {init_args, InitialState, InitialData, Handler, StateEnter, Parent, AckTag, Name, OnCodeChange,
        OnFormatStatus}
) ->
    %% Build the ServerRef and determine the tag used for info-message
    %% unwrapping. For unnamed and Local-named servers the ref carries a
    %% Subject, so the tag matches what callers send via process.send. For
    %% Global/Via, no Subject is associated, but we still pick a fresh
    %% reference as the tag so unrelated info messages always pass through
    %% raw (the ref will never collide with an external sender).
    {ServerRef, SubjectTag} = build_server_ref(Name),

    %% Send the ServerRef to the parent before gen_statem unblocks the
    %% start* call.
    Parent ! {AckTag, ServerRef},

    GleamStatem = #gleam_statem{
        gleam_state = InitialState,
        gleam_data = InitialData,
        gleam_handler = Handler,
        state_enter = StateEnter,
        subject_tag = SubjectTag,
        on_code_change = OnCodeChange,
        on_format_status = OnFormatStatus
    },

    {ok, InitialState, GleamStatem}.

-spec build_server_ref(server_name_option()) -> {tuple(), term()}.
build_server_ref(none) ->
    Tag = make_ref(),
    {{server_ref_subject, {subject, self(), Tag}}, Tag};
build_server_ref({some, {local, NameAtom}}) ->
    {{server_ref_subject, {named_subject, NameAtom}}, NameAtom};
build_server_ref({some, {global, GlobalName}}) ->
    {{server_ref_global, GlobalName}, make_ref()};
build_server_ref({some, {via, Mod, Term}}) ->
    {{server_ref_via, Mod, Term}, make_ref()}.

-doc """
Always advertise `handle_event_function` + `state_enter`.

`state_enter` cannot be made conditional here because `callback_mode/0`
is called before `init/1`. The `handle_event/4` guard below filters out
enter events when the user did not opt in.
""".
callback_mode() ->
    [handle_event_function, state_enter].

-doc """
Either drops `enter` events when the user did not opt in to `state_enter`.
Or translates all other events through the Gleam handler.
""".
handle_event(
    enter,
    _OldState,
    _CurrentState,
    #gleam_statem{state_enter = state_enter_disabled} = GleamStatem
) ->
    {keep_state, GleamStatem};
handle_event(
    EventType,
    EventContent,
    State,
    #gleam_statem{
        gleam_handler = Handler,
        gleam_data = Data
    } = GleamStatem
) ->
    GleamEvent = convert_event_to_gleam(
        EventType,
        EventContent,
        State,
        GleamStatem
    ),
    GleamStep = Handler(GleamEvent, State, Data),
    convert_step_to_erlang(GleamStep, GleamStatem).

-doc """
Cleanup on termination.
""".
terminate(_Reason, _State, _GleamStatem) ->
    ok.

-doc """
Hot-code upgrade, calls the user-provided migration function (if set).

When the user calls `statem.on_code_change(builder, fn(data) { ... })`, the
migration function is invoked with the current data and its return value
becomes the new data. If no function was set, the data passes through
unchanged.
""".
code_change(
    _OldVsn,
    State,
    #gleam_statem{
        gleam_data = Data,
        on_code_change = OnCodeChange
    } = GleamStatem,
    _Extra
) ->
    NewData =
        case OnCodeChange of
            none -> Data;
            {some, F} -> F(Data)
        end,
    {ok, State, GleamStatem#gleam_statem{gleam_data = NewData}}.

-doc """
Format the state/data for `sys:get_status/1` and SASL crash reports.

OTP 25+ semantics: receives a status map containing `state`, `data`, and an
optional subset of `reason`, `queue`, `postponed`, `timeouts`, `log`. The
internal `#gleam_statem{}` lives under `data`; we extract the user's
`gleam_data` before calling the Gleam-side formatter, and write the
formatter's returned value back into the map's `data` key unwrapped (the
result is purely for display, never becomes the live process data).

Keys that were absent from the input map are not introduced in the output,
matching OTP's contract that `NewStatus` has the same elements as `Status`.
""".
format_status(
    #{
        state := State,
        data := #gleam_statem{
            on_format_status = OnFormatStatus,
            gleam_data = GleamData,
            subject_tag = SubjectTag
        }
    } = Status
) ->
    case OnFormatStatus of
        none ->
            Status;
        {some, Fun} ->
            Reason = classify_reason_opt(Status),
            Queue = classify_queue_entries(maps:get(queue, Status, []), SubjectTag),
            Postponed = classify_queue_entries(maps:get(postponed, Status, []), SubjectTag),
            Timeouts = classify_timeouts(maps:get(timeouts, Status, [])),
            Log = maps:get(log, Status, []),
            %% Gleam Status record on the Erlang side:
            %% {status, state, data, reason, queue, postponed, timeouts, log}
            GleamStatus =
                {status, State, GleamData, Reason, Queue, Postponed, Timeouts, Log},
            {status, NewState, NewData, NewReason, NewQueue, NewPostponed, NewTimeouts, NewLog} =
                Fun(GleamStatus),
            %% maps:map/2 walks only the keys already in Status, so optional
            %% keys that were absent in the input stay absent in the output,
            %% honouring OTP's "NewStatus has the same elements as Status"
            %% contract. The final clause passes through any future keys OTP
            %% adds to the status map.
            maps:map(
                fun
                    (state, _) ->
                        NewState;
                    (data, _) ->
                        NewData;
                    (reason, OrigReason) ->
                        case NewReason of
                            none -> OrigReason;
                            {some, R} -> unclassify_reason(R)
                        end;
                    (queue, _) ->
                        [unclassify_queue_entry(E) || E <- NewQueue];
                    (postponed, _) ->
                        [unclassify_queue_entry(E) || E <- NewPostponed];
                    (timeouts, _) ->
                        [unclassify_timeout(T) || T <- NewTimeouts];
                    (log, _) ->
                        NewLog;
                    (_, V) ->
                        V
                end,
                Status
            )
    end.

%%%===================================================================
%%% format_status: Erlang <-> Gleam conversions
%%%
%%% All classify_* converters aim for typed Gleam variants; any shape
%%% we cannot confidently map is wrapped in an *_other variant carrying
%%% the raw term, so format_status never crashes on unexpected input.
%%%===================================================================

classify_reason_opt(Status) ->
    case maps:find(reason, Status) of
        {ok, R} -> {some, classify_reason(R)};
        error -> none
    end.

%% Gleam process.ExitReason is {normal} | {killed} | {abnormal, Term}.
%% Wrap recognised shapes as Exit(...); everything else as RawReason(term).
classify_reason(normal) -> {exit, {normal}};
classify_reason(killed) -> {exit, {killed}};
classify_reason({abnormal, T}) -> {exit, {abnormal, T}};
classify_reason(Other) -> {raw_reason, Other}.

unclassify_reason({exit, {normal}}) -> normal;
unclassify_reason({exit, {killed}}) -> killed;
unclassify_reason({exit, {abnormal, T}}) -> {abnormal, T};
unclassify_reason({raw_reason, Term}) -> Term.

classify_queue_entries(Entries, SubjectTag) ->
    [classify_queue_entry(E, SubjectTag) || E <- Entries].

classify_queue_entry({{call, From}, Content}, _) ->
    {queued_call, From, Content};
classify_queue_entry({cast, Content}, _) ->
    {queued_cast, Content};
classify_queue_entry({info, Content}, SubjectTag) ->
    %% Match handle_event/4's behaviour: unwrap messages sent via the Subject,
    %% pass through raw Erlang terms unchanged.
    Msg =
        case Content of
            {SubjectTag, M} -> M;
            _ -> Content
        end,
    {queued_info, Msg};
classify_queue_entry({internal, Content}, _) ->
    {queued_internal, Content};
classify_queue_entry({state_timeout, Content}, _) ->
    {queued_state_timeout, Content};
classify_queue_entry({timeout, Content}, _) ->
    {queued_event_timeout, Content};
classify_queue_entry({{timeout, Name}, Content}, _) when is_binary(Name) ->
    {queued_generic_timeout, Name, Content};
classify_queue_entry(Other, _) ->
    {queued_other, Other}.

unclassify_queue_entry({queued_call, From, Content}) -> {{call, From}, Content};
unclassify_queue_entry({queued_cast, Content}) -> {cast, Content};
unclassify_queue_entry({queued_info, Msg}) -> {info, Msg};
unclassify_queue_entry({queued_internal, Content}) -> {internal, Content};
unclassify_queue_entry({queued_state_timeout, Content}) -> {state_timeout, Content};
unclassify_queue_entry({queued_event_timeout, Content}) -> {timeout, Content};
unclassify_queue_entry({queued_generic_timeout, Name, Content}) -> {{timeout, Name}, Content};
unclassify_queue_entry({queued_other, Raw}) -> Raw.

classify_timeouts(Entries) ->
    [classify_timeout(E) || E <- Entries].

classify_timeout({state_timeout, Content}) ->
    {active_state_timeout, Content};
classify_timeout({timeout, Content}) ->
    {active_event_timeout, Content};
classify_timeout({{timeout, Name}, Content}) when is_binary(Name) ->
    {active_generic_timeout, Name, Content};
classify_timeout(Other) ->
    {active_other_timeout, Other}.

unclassify_timeout({active_state_timeout, Content}) -> {state_timeout, Content};
unclassify_timeout({active_event_timeout, Content}) -> {timeout, Content};
unclassify_timeout({active_generic_timeout, Name, Content}) -> {{timeout, Name}, Content};
unclassify_timeout({active_other_timeout, Raw}) -> Raw.

%%%===================================================================
%%% Event conversion from Erlang to Gleam
%%%===================================================================

-doc """
Converts a `gen_statem` event into the Gleam Event union type.

Info events are unwrapped: if the first element of the message tuple
matches the Subject tag stored in `#gleam_statem`, the wrapper is
stripped so the Gleam handler receives `Info(Msg)` rather than
`Info({Tag, Msg})`.
""".
convert_event_to_gleam(EventType, EventContent, _State, GleamStatem) ->
    case EventType of
        {call, From} ->
            %% Synchronous gen_statem call (Erlang interop).
            %% Gleam: Call(from: From(reply), message: msg)
            %% From is an external type, passed through as-is.
            {call, From, EventContent};
        cast ->
            %% Asynchronous gen_statem cast (Erlang interop).
            %% Gleam: Cast(message: msg)
            {cast, EventContent};
        info ->
            %% Messages delivered to this process's mailbox.
            %% Unwrap if sent via our Subject (process.send).
            SubjectTag = GleamStatem#gleam_statem.subject_tag,
            case EventContent of
                {SubjectTag, Msg} ->
                    %% Message was sent via process.send(subject, Msg).
                    {info, Msg};
                Other ->
                    %% Raw Erlang message (monitor signals, raw sends, etc.).
                    {info, Other}
            end;
        enter ->
            %% State-entry callback: EventContent is the previous state.
            %% Gleam: Enter(old_state: state)
            {enter, EventContent};
        state_timeout ->
            %% State timeout fired.
            %% Gleam: Timeout(StateTimeoutType, content)
            {timeout, state_timeout_type, EventContent};
        timeout ->
            %% Unnamed event timeout fired.
            %% Gleam: Timeout(EventTimeoutType, content)
            {timeout, event_timeout_type, EventContent};
        {timeout, Name} ->
            %% Named generic timeout fired.
            %% Gleam: Timeout(GenericTimeoutType(name), content)
            {timeout, {generic_timeout_type, Name}, EventContent};
        internal ->
            %% Internal events are fired by the NextEvent action.
            %% Map to Cast so the user pattern-matches them as Cast(msg).
            {cast, EventContent};
        _Other ->
            %% Truly unknown event type, wrap as Info so the user can handle
            %% or ignore it in their catch-all clause.
            {info, {unexpected_event, EventType, EventContent}}
    end.

%%%===================================================================
%%% Step conversion
%%% Gleam to Erlang
%%%===================================================================

-doc """
Converts a Gleam Step back to the `gen_statem` result tuple format.
""".
convert_step_to_erlang(GleamStep, GleamStatem) ->
    case GleamStep of
        {next_state, NewState, NewData, GleamActions} ->
            Actions = convert_actions_to_erlang(GleamActions),
            NewGleamStatem = GleamStatem#gleam_statem{
                gleam_state = NewState,
                gleam_data = NewData
            },
            case Actions of
                [] -> {next_state, NewState, NewGleamStatem};
                _ -> {next_state, NewState, NewGleamStatem, Actions}
            end;
        {keep_state, NewData, GleamActions} ->
            Actions = convert_actions_to_erlang(GleamActions),
            NewGleamStatem = GleamStatem#gleam_statem{
                gleam_data = NewData
            },
            case Actions of
                [] -> {keep_state, NewGleamStatem};
                _ -> {keep_state, NewGleamStatem, Actions}
            end;
        {keep_state_and_data, GleamActions} ->
            Actions = convert_actions_to_erlang(GleamActions),
            case Actions of
                [] -> keep_state_and_data;
                _ -> {keep_state_and_data, Actions}
            end;
        {repeat_state, NewData, GleamActions} ->
            Actions = convert_actions_to_erlang(GleamActions),
            NewGleamStatem = GleamStatem#gleam_statem{
                gleam_data = NewData
            },
            case Actions of
                [] -> {repeat_state, NewGleamStatem};
                _ -> {repeat_state, NewGleamStatem, Actions}
            end;
        {repeat_state_and_data, GleamActions} ->
            Actions = convert_actions_to_erlang(GleamActions),
            case Actions of
                [] -> repeat_state_and_data;
                _ -> {repeat_state_and_data, Actions}
            end;
        {stop, Reason} ->
            {stop, convert_exit_reason(Reason)};
        {stop_and_reply, Reason, GleamActions} ->
            Replies = convert_actions_to_erlang(GleamActions),
            {stop_and_reply, convert_exit_reason(Reason), Replies}
    end.

convert_actions_to_erlang(GleamActions) ->
    lists:map(fun convert_action_to_erlang/1, GleamActions).

convert_action_to_erlang(Action) ->
    case Action of
        {reply, From, Response} ->
            %% Reply to a gen_statem:call caller.
            %% From is the external type, the raw gen_statem:from() term.
            {reply, From, Response};
        hibernate ->
            hibernate;
        postpone ->
            postpone;
        {next_event, internal_event, Content} ->
            {next_event, internal, Content};
        {next_event, cast_event, Content} ->
            {next_event, cast, Content};
        {next_event, info_event, Content} ->
            {next_event, info, Content};
        {next_event, {call_event, From}, Content} ->
            {next_event, {call, From}, Content};
        {state_timeout, Time, Content} ->
            timeout_action(state_timeout, Time, Content);
        {event_timeout, Time, Content} ->
            timeout_action(timeout, Time, Content);
        {generic_timeout, Name, Time, Content} ->
            timeout_action({timeout, Name}, Time, Content);
        cancel_state_timeout ->
            {state_timeout, cancel};
        cancel_event_timeout ->
            {timeout, cancel};
        {cancel_generic_timeout, Name} ->
            {{timeout, Name}, cancel};
        {update_state_timeout, Content} ->
            {state_timeout, update, Content};
        {update_event_timeout, Content} ->
            {timeout, update, Content};
        {update_generic_timeout, Name, Content} ->
            {{timeout, Name}, update, Content};
        {change_callback_module, Module} ->
            {change_callback_module, Module};
        {push_callback_module, Module} ->
            {push_callback_module, Module};
        pop_callback_module ->
            pop_callback_module
    end.

%% Build a gen_statem timeout action tuple from the Gleam TimeoutTime
%% discriminator. `After` produces the 3-tuple form (relative ms);
%% `At` produces the 4-tuple form with `[{abs, true}]` so `Ms` is treated
%% as an absolute erlang:monotonic_time(millisecond) deadline.
timeout_action(Tag, {'after', Ms}, Content) ->
    {Tag, Ms, Content};
timeout_action(Tag, {at, Ms}, Content) ->
    {Tag, Ms, Content, [{abs, true}]}.

subject_to_pid({subject, Pid, _Tag}) ->
    Pid;
subject_to_pid({named_subject, Name}) ->
    case erlang:whereis(Name) of
        Pid when is_pid(Pid) -> Pid;
        undefined -> error({noproc, Name})
    end.

-doc """
Sends an asynchronous `cast` to a running `gen_statem` via its `ServerRef`.

Resolves the ref to the appropriate `gen_statem`-compatible target and calls
`gen_statem:cast/2`. The message arrives in `handle_event/4` with
`EventType=cast` and is converted to `Cast(Msg)` for the Gleam handler.
""".
cast(ServerRef, Msg) ->
    gen_statem:cast(ref_target(ServerRef), Msg),
    nil.

-doc """
Resolve a `ServerRef` to the target shape accepted by `gen_statem:cast/2`,
`gen_statem:call/3`, and `gen_statem:send_request/2`.
""".
-spec ref_target(tuple()) -> pid() | atom() | {global, atom()} | {via, atom(), term()}.
ref_target({server_ref_subject, {subject, Pid, _Tag}}) -> Pid;
ref_target({server_ref_subject, {named_subject, Name}}) -> Name;
ref_target({server_ref_global, Name}) -> {global, Name};
ref_target({server_ref_via, Mod, Term}) -> {via, Mod, Term};
ref_target({server_ref_pid, Pid}) -> Pid.

-doc """
Extract the `Subject(message)` underlying a `ServerRef`. Succeeds for refs
returned by unnamed and `Local`-named starts; returns `{error, nil}` for
`Global`, `Via`, or raw-Pid refs.
""".
-spec ref_to_subject(tuple()) -> {ok, tuple()} | {error, nil}.
ref_to_subject({server_ref_subject, Subject}) -> {ok, Subject};
ref_to_subject(_) -> {error, nil}.

-doc "Wrap an existing Gleam `Subject(message)` as a `ServerRef(message)`.".
ref_from_subject(Subject) -> {server_ref_subject, Subject}.

-doc """
Wrap a raw `Pid` as a `ServerRef(message)`. Suitable for `cast` and
`send_request`; not convertible back to a `Subject` because no subject tag
is associated.
""".
ref_from_pid(Pid) when is_pid(Pid) -> {server_ref_pid, Pid}.

-doc "Stop a running state machine with reason `normal`.".
stop_server(Subject) ->
    gen_statem:stop(subject_to_pid(Subject)),
    nil.

-doc "Stop a running state machine with a custom reason and timeout (ms).".
stop_server_with(Subject, Reason, Timeout) ->
    gen_statem:stop(subject_to_pid(Subject), convert_exit_reason(Reason), Timeout),
    nil.

-doc "Send a reply to a caller from outside the state machine callback.".
send_reply(From, Reply) ->
    gen_statem:reply(From, Reply),
    nil.

-doc """
Send multiple replies at once.
Gleam's #(From, Reply) tuples are {From, Reply} in Erlang and must be
converted to gen_statem reply actions {reply, From, Reply}.
""".
send_replies(Replies) ->
    Actions = [{reply, F, R} || {F, R} <- Replies],
    gen_statem:reply(Actions),
    nil.

-doc "Block indefinitely until a reply arrives. Since OTP 23.".
wait_response(ReqId) ->
    case gen_statem:wait_response(ReqId) of
        {reply, Reply} -> {ok, Reply};
        {error, {Reason, _}} -> {error, {request_crashed, classify_reason(Reason)}}
    end.

-doc "Block until a reply arrives or the timeout (ms) expires. Since OTP 23.".
wait_response_timeout(ReqId, Timeout) ->
    case gen_statem:wait_response(ReqId, Timeout) of
        {reply, Reply} -> {ok, Reply};
        timeout -> {error, receive_timeout};
        {error, {Reason, _}} -> {error, {request_crashed, classify_reason(Reason)}}
    end.

-doc "Block indefinitely waiting for the reply to a single ReqId. Since OTP 24.".
receive_response_blocking(ReqId) ->
    case gen_statem:receive_response(ReqId) of
        {reply, Reply} -> {ok, Reply};
        {error, {Reason, _ServerRef}} -> {error, {request_crashed, classify_reason(Reason)}}
    end.

-doc """
Check if a received message is the reply for a request. Since OTP 23.
Returns {ok, {some, Reply}}, {ok, none}, or {error, StopReason}.
""".
check_response(Msg, ReqId) ->
    case gen_statem:check_response(Msg, ReqId) of
        {reply, Reply} -> {ok, {some, Reply}};
        no_reply -> {ok, none};
        {error, {Reason, _}} -> {error, {request_crashed, classify_reason(Reason)}}
    end.

%%%===================================================================
%%% reqids API (OTP 25.0+)
%%%===================================================================

-doc "Creates a new empty request-id collection.".
reqids_new() ->
    gen_statem:reqids_new().

-doc "Adds a request id to a collection under the given label.".
reqids_add(ReqId, Label, Collection) ->
    gen_statem:reqids_add(ReqId, Label, Collection).

-doc "Returns the number of request ids in the collection.".
reqids_size(Collection) ->
    gen_statem:reqids_size(Collection).

-doc "Converts the collection to a list of {ReqId, Label} pairs.".
reqids_to_list(Collection) ->
    gen_statem:reqids_to_list(Collection).

-doc """
Sends an asynchronous call request to a gen_statem process and returns a
request id. The server receives a `Call(from, msg)` event and must respond
with a `Reply(from, value)` action. Use `receive_response/2` to collect the
reply when ready.
""".
send_request(ServerRef, Msg) ->
    gen_statem:send_request(ref_target(ServerRef), Msg).

-doc """
Like `send_request/2` but also adds the resulting request id (under `Label`)
to `Collection`, returning the updated collection.
""".
send_request_to_collection(ServerRef, Msg, Label, Collection) ->
    gen_statem:send_request(ref_target(ServerRef), Msg, Label, Collection).

-doc """
Waits up to `Timeout` milliseconds for the reply to a single `ReqId`.
Returns `{ok, Reply}` on success, `{error, receive_timeout}` on timeout,
or `{error, {request_crashed, StopReason}}` if the server terminated.
""".
receive_response(ReqId, Timeout) ->
    case gen_statem:receive_response(ReqId, Timeout) of
        {reply, Reply} ->
            {ok, Reply};
        timeout ->
            {error, receive_timeout};
        {error, {Reason, _ServerRef}} ->
            {error, {request_crashed, classify_reason(Reason)}}
    end.

-doc """
Waits up to `Timeout` milliseconds for any reply in `Collection`.
`Handling` is the atom `delete` (remove the matched request from the
returned collection) or `keep`. Maps to Gleam's `CollectionResponse`
constructors:
  `{got_reply, Reply, Label, NewColl}`
  `{request_failed, StopReason, Label, NewColl}`
  `no_requests`
""".
receive_response_collection(Collection, Timeout, Handling) ->
    Delete =
        case Handling of
            delete -> true;
            keep -> false
        end,
    case gen_statem:receive_response(Collection, Timeout, Delete) of
        {{reply, Reply}, Label, NewColl} ->
            {got_reply, Reply, Label, NewColl};
        {{error, {Reason, _ServerRef}}, Label, NewColl} ->
            {request_failed, classify_reason(Reason), Label, NewColl};
        no_request ->
            no_requests
    end.

-doc """
Converts a Gleam ExitReason to an Erlang exit reason term.
""".
convert_exit_reason(Reason) ->
    case Reason of
        {normal} -> normal;
        {killed} -> killed;
        {abnormal, Term} -> {abnormal, Term};
        _ -> Reason
    end.
