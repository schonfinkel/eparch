-module(statem_ffi).
-moduledoc """
Erlang FFI bridge for the statem Gleam module. Translates between Erlang's
gen_statem behavior callbacks and Gleam's type-safe API.
""".

-behaviour(gen_statem).

%% Public API
-export([do_start/7, cast/2, from_for_testing/0]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    handle_event/4,
    terminate/3,
    code_change/4
]).

%%%===================================================================
%%% Internal state record
%%%===================================================================

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
    subject_tag,
    % - unnamed: reference (make_ref())
    % - named: atom (the registered name)

    % none | {some, fn(data) -> data}
    on_code_change
}).

%%%===================================================================
%%% API
%%% called from Gleam via @external
%%%===================================================================
-doc """
Creates a dummy `gen_statem:from()` value for use in unit tests.

`gen_statem:from()` is `{Pid, Tag}` internally. The returned value is only
ever used for equality comparisons in pure unit tests, it is never
passed to `gen_statem:reply/2`.
""".
-spec from_for_testing() -> {pid(), reference()}.
from_for_testing() ->
    {self(), make_ref()}.

-doc """
Start a `gen_statem` process linked to the caller and return the Subject 
needed to send messages to it
""".
do_start(InitialState, InitialData, Handler, StateEnter, Timeout, Name, OnCodeChange) ->
    %% Ack channel: a unique reference the child process will use to
    %% send us the Subject it creates in init/1.
    AckTag = make_ref(),
    Parent = self(),

    InitArgs =
        {init_args, InitialState, InitialData, Handler, StateEnter, Parent, AckTag, Name,
            OnCodeChange},

    StartResult =
        case Name of
            none ->
                gen_statem:start_link(?MODULE, InitArgs, [{timeout, Timeout}]);
            {some, ProcessName} ->
                gen_statem:start_link(
                    {local, ProcessName},
                    ?MODULE,
                    InitArgs,
                    [{timeout, Timeout}]
                )
        end,

    case StartResult of
        {ok, Pid} ->
            %% init/1 runs synchronously inside start_link, so the Subject
            %% is already waiting in our mailbox.  Use after 0 as a safety
            %% net; in practice the message is always there.
            receive
                {AckTag, Subject} ->
                    {ok, {started, Pid, Subject}}
            after 0 ->
                %% Should never happen — indicates a bug in init/1.
                {error, {init_failed, <<"init/1 did not deliver a Subject">>}}
            end;
        {error, timeout} ->
            {error, init_timeout};
        {error, {already_started, _OtherPid}} ->
            {error, {init_failed, <<"process name already registered">>}};
        {error, Reason} ->
            {error, {init_exited, {abnormal, Reason}}}
    end.

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================
-doc """
Initialise the gen_statem process.

Creates the Subject for this process and sends it back to the parent
through the ack channel before returning to gen_statem.
""".
init(
    {init_args, InitialState, InitialData, Handler, StateEnter, Parent, AckTag, Name, OnCodeChange}
) ->
    %% Build the Subject and determine the tag used for message unwrapping.
    {Subject, SubjectTag} =
        case Name of
            none ->
                %% Unnamed process: tag is a unique reference, subject is the
                %% standard {subject, Pid, Tag} Gleam variant.
                Tag = make_ref(),
                {{subject, self(), Tag}, Tag};
            {some, ProcessName} ->
                %% Named process: tag is the atom, subject is the
                %% {named_subject, Name} Gleam variant.
                {{named_subject, ProcessName}, ProcessName}
        end,

    %% Send the Subject to the parent before gen_statem unblocks start_link.
    Parent ! {AckTag, Subject},

    GleamStatem = #gleam_statem{
        gleam_state = InitialState,
        gleam_data = InitialData,
        gleam_handler = Handler,
        state_enter = StateEnter,
        subject_tag = SubjectTag,
        on_code_change = OnCodeChange
    },

    {ok, InitialState, GleamStatem}.

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
            %% From is an external type — passed through as-is.
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
            %% Gleam: Timeout(StateTimeoutType)
            {timeout, state_timeout_type};
        {timeout, Name} ->
            %% Named generic timeout fired.
            %% Gleam: Timeout(GenericTimeoutType(name))
            {timeout, {generic_timeout_type, Name}};
        internal ->
            %% Internal events are fired by the NextEvent action.
            %% Map to Cast so the user pattern-matches them as Cast(msg).
            {cast, EventContent};
        _Other ->
            %% Truly unknown event type — wrap as Info so the user can handle
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
        {stop, Reason} ->
            {stop, convert_exit_reason(Reason)}
    end.

convert_actions_to_erlang(GleamActions) ->
    lists:map(fun convert_action_to_erlang/1, GleamActions).

convert_action_to_erlang(Action) ->
    case Action of
        {reply, From, Response} ->
            %% Reply to a gen_statem:call caller.
            %% From is the external type — the raw gen_statem:from() term.
            {reply, From, Response};
        postpone ->
            postpone;
        {next_event, Content} ->
            {next_event, internal, Content};
        {state_timeout, Milliseconds} ->
            {state_timeout, Milliseconds, timeout};
        {generic_timeout, Name, Milliseconds} ->
            {{timeout, Name}, Milliseconds, timeout}
    end.

-doc """
Sends an asynchronous `cast` to a running `gen_statem` process.

Extracts the `Pid` from the Gleam Subject and calls `gen_statem:cast/2`.
The message arrives in `handle_event/4` with `EventType=cast` and is
converted to `Cast(Msg)` for the Gleam handler.
""".
cast(Subject, Msg) ->
    Pid =
        case Subject of
            {subject, P, _Tag} ->
                P;
            {named_subject, Name} ->
                case erlang:whereis(Name) of
                    P when is_pid(P) -> P;
                    undefined -> error({noproc, Name})
                end
        end,
    gen_statem:cast(Pid, Msg),
    nil.

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
