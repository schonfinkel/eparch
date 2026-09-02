-module(eparch_options_ffi).
-moduledoc """
Shared encoders for the start-option types defined in `eparch/start_options`.
Used by both `statem_ffi` and `event_manager_ffi` so the Gleam-to-Erlang
mapping for `Timeout`, `DebugFlag`, `SpawnOption`, `Priority`, and
`MessageQueueMode` lives in exactly one place.
""".

-export([
    timeout_to_erlang/1,
    debug_to_erlang/1,
    spawn_opt_to_erlang/1,
    priority_to_erlang/1,
    mq_mode_to_erlang/1,
    build_extra_opts/2
]).

-doc "Converts a Gleam `Timeout` to an Erlang `timeout()` value.".
timeout_to_erlang(infinity) -> infinity;
timeout_to_erlang({milliseconds, Ms}) -> Ms.

-doc "Converts a Gleam `DebugFlag` to an Erlang `sys:dbg_opt()` term.".
debug_to_erlang(debug_trace) -> trace;
debug_to_erlang(debug_log) -> log;
debug_to_erlang(debug_statistics) -> statistics;
debug_to_erlang({debug_log_to_file, FileName}) -> {log_to_file, FileName}.

-doc "Converts a Gleam `SpawnOption` to an Erlang `spawn_opt/2` option.".
spawn_opt_to_erlang({spawn_priority, Level}) ->
    {priority, priority_to_erlang(Level)};
spawn_opt_to_erlang({spawn_fullsweep_after, N}) ->
    {fullsweep_after, N};
spawn_opt_to_erlang({spawn_min_heap_size, N}) ->
    {min_heap_size, N};
spawn_opt_to_erlang({spawn_min_bin_vheap_size, N}) ->
    {min_bin_vheap_size, N};
spawn_opt_to_erlang({spawn_max_heap_size, N}) ->
    {max_heap_size, N};
spawn_opt_to_erlang({spawn_message_queue_data, Mode}) ->
    {message_queue_data, mq_mode_to_erlang(Mode)}.

-doc "Converts a Gleam `Priority` atom to its Erlang counterpart.".
priority_to_erlang(priority_low) -> low;
priority_to_erlang(priority_normal) -> normal;
priority_to_erlang(priority_high) -> high;
priority_to_erlang(priority_max) -> max.

-doc "Converts a Gleam `MessageQueueMode` atom to its Erlang counterpart.".
mq_mode_to_erlang(on_heap) -> on_heap;
mq_mode_to_erlang(off_heap) -> off_heap.

-doc """
Build the optional `[{debug, _}, {spawn_opt, _}]` tail of a behaviour's
start-option list. Empty lists are skipped so unused options are not present
in the result.
""".
build_extra_opts(DebugFlags, SpawnOpts) ->
    case DebugFlags of
        [] -> [];
        _ -> [{debug, [debug_to_erlang(F) || F <- DebugFlags]}]
    end ++
        case SpawnOpts of
            [] -> [];
            _ -> [{spawn_opt, [spawn_opt_to_erlang(O) || O <- SpawnOpts]}]
        end.
