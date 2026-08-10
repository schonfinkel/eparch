-module(eparch_test_helpers).
-moduledoc """
Test-only helpers used by `start_options_test.gleam`. Pure encoding glue:
build the Erlang-shape values that Gleam cannot construct through its
own type system (e.g. the raw `{global, Name}` tuple consumed by
`gen_statem:cast/2`).
""".

-export([
    encode_global_target/1,
    encode_atom_as_term/1,
    encode_ping/1,
    sys_get_status_text/1
]).

-doc "Build the `{global, Name}` server-ref tuple consumed by `gen_statem`.".
encode_global_target(Name) -> {global, Name}.

-doc "Pass an atom through as an opaque dynamic term.".
encode_atom_as_term(Atom) -> Atom.

-doc """
Build a Gleam `Msg::Ping(reply_with: subject)` value at the Erlang level.
Gleam encodes the `Ping` variant as the tagged tuple `{ping, Subject}`.
""".
encode_ping(ReplySubject) ->
    {ping, ReplySubject}.

-doc """
Render `sys:get_status/1` as text so Gleam can assert against it.

The status is a deeply nested Erlang term with no stable Gleam shape, so
formatting it here is cheaper than decoding it. Used to check that the
`gen_statem` state really is the protocol tag.
""".
sys_get_status_text(Pid) ->
    unicode:characters_to_binary(io_lib:format("~p", [sys:get_status(Pid)])).
