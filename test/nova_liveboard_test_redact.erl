-module(nova_liveboard_test_redact).
-moduledoc """
Test fixtures for redaction: a `redact` callback, and a supervisor with one
atom child id and one child id built from a connection string.
""".
-behaviour(supervisor).

-export([shown/2, broken/2]).
-export([init/1, idle/0]).

-type kind() :: request_path | port_name | child_id.

-spec shown(kind(), binary()) -> binary().
shown(request_path, <<"/files/", _/binary>>) -> ~"/files/:name";
shown(port_name, _Name) -> ~"a port";
shown(child_id, Id) -> <<"child ", Id/binary>>;
shown(_Kind, Value) -> Value.

-spec broken(kind(), binary()) -> not_a_binary.
broken(request_path, _Path) -> not_a_binary;
broken(port_name, _Name) -> error(boom);
broken(child_id, _Id) -> throw(nope).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Children = [
        #{id => Id, start => {?MODULE, idle, []}}
     || Id <- [plain, {pool, "postgres://app:hunter2@db/prod"}]
    ],
    {ok, {#{strategy => one_for_one}, Children}}.

-spec idle() -> {ok, pid()}.
idle() ->
    {ok,
        proc_lib:spawn_link(fun() ->
            receive
                stop -> ok
            end
        end)}.
