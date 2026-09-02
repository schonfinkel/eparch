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
    encode_ping/1
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
