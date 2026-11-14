-module(nova_liveboard).
-moduledoc """
Configuration helpers for the liveboard.

All settings live under the `nova_liveboard` application env:

| Key | Default | Accepted |
|-----|---------|----------|
| `auth` | none, required | `{Module, Function}` or `none`, see `auth/0` |
| `prefix` | `"/liveboard"` | a string or binary: empty, or starting with `/` and not ending with `/` |
| `refresh_ms` | `2000` | a positive integer |
| `request_buffer` | `200` | a positive integer |
| `max_streams` | `50` | a non-negative integer |
| `max_streams_per_client` | `6` | a non-negative integer |
| `stream_lifetime_ms` | `300000` | a positive integer |
| `redact` | `standard` | `standard`, `none`, `all` or `{Module, Function}`, see `m:nova_liveboard_redact` |
| `trusted_origins` | `[]` | a list of origins as binaries, see `trusted_origins/0` |

`validate/0` checks every key but `auth` against this table. It runs when the
liveboard's routes are built and again when the application starts, and
either one refuses to go on when a value is not accepted. The failure names
the key and what it accepts, never the value that was set.

The accessors below read the env on every call and never fail. A value of the
wrong type that is set while the node runs is not used: the accessor answers
with the default, or for `redact` with `all`.
""".

-export([
    validate/0,
    prefix/0,
    refresh_ms/0,
    request_buffer/0,
    max_streams/0,
    max_streams_per_client/0,
    stream_lifetime_ms/0,
    auth/0,
    trusted_origins/0,
    redact/0
]).

-define(PREFIX, ~"/liveboard").
-define(REQUEST_BUFFER, 200).
-define(VALIDATED, [
    prefix,
    refresh_ms,
    request_buffer,
    max_streams,
    max_streams_per_client,
    stream_lifetime_ms,
    redact,
    trusted_origins
]).

-type auth() :: none | {module(), atom()}.
-type auth_error() ::
    auth_not_configured
    | invalid_auth
    | {auth_callback_not_exported, {module(), atom(), 1}}.
-type invalid() :: {Key :: atom(), Accepted :: binary()}.

-export_type([auth/0, auth_error/0, invalid/0]).

-doc """
Check the settings against what they accept (see the table above). Returns
`ok`, or every key whose value is not accepted together with a description of
what is. A key that is not set is fine: it has a default.
""".
-spec validate() -> ok | {error, [invalid(), ...]}.
validate() ->
    case [{Key, accepted(Key)} || Key <- ?VALIDATED, not valid(Key)] of
        [] -> ok;
        [_ | _] = Invalid -> {error, Invalid}
    end.

-doc """
The mount path as a binary: empty when the liveboard is mounted at the root,
otherwise with a leading slash. A value that is neither a string nor a binary
is not used; the default is.
""".
-spec prefix() -> binary().
prefix() ->
    case text(application:get_env(nova_liveboard, prefix, ?PREFIX)) of
        {ok, Prefix} -> Prefix;
        error -> ?PREFIX
    end.

-doc "Repaint interval for the polled (non-request) streams, in milliseconds.".
-spec refresh_ms() -> pos_integer().
refresh_ms() ->
    case application:get_env(nova_liveboard, refresh_ms, 2000) of
        N when is_integer(N), N > 0 -> N;
        _ -> 2000
    end.

-doc "How many live streams may be open at once. Default 50.".
-spec max_streams() -> non_neg_integer().
max_streams() ->
    case application:get_env(nova_liveboard, max_streams, 50) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 50
    end.

-doc """
How many of the open live streams one client may hold. Default 6, which is
three open pages. See `nova_liveboard_sse:client/1` for what a client is.
""".
-spec max_streams_per_client() -> non_neg_integer().
max_streams_per_client() ->
    case application:get_env(nova_liveboard, max_streams_per_client, 6) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 6
    end.

-doc "How long one live stream may stay open before the browser must reconnect. Default 5 minutes.".
-spec stream_lifetime_ms() -> pos_integer().
stream_lifetime_ms() ->
    case application:get_env(nova_liveboard, stream_lifetime_ms, 300000) of
        N when is_integer(N), N > 0 -> N;
        _ -> 300000
    end.

-doc "How many completed requests the tracer ring buffer retains.".
-spec request_buffer() -> pos_integer().
request_buffer() ->
    case application:get_env(nova_liveboard, request_buffer, ?REQUEST_BUFFER) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?REQUEST_BUFFER
    end.

-doc """
Who may use the liveboard. There is no default: the host must set `auth` to

- `{Module, Function}`, a Nova security callback `Module:Function(Req)` that is
  put on every liveboard route, or
- `none`, the explicit opt-out for a liveboard that is protected some other
  way.

Anything else is an error and the router refuses to build its routes. The
error does not carry the value that was set.
""".
-spec auth() -> {ok, auth()} | {error, auth_error()}.
auth() ->
    case application:get_env(nova_liveboard, auth) of
        {ok, none} ->
            {ok, none};
        {ok, {Module, Function}} when is_atom(Module), is_atom(Function) ->
            case
                code:ensure_loaded(Module) =:= {module, Module} andalso
                    erlang:function_exported(Module, Function, 1)
            of
                true -> {ok, {Module, Function}};
                false -> {error, {auth_callback_not_exported, {Module, Function, 1}}}
            end;
        {ok, _Other} ->
            {error, invalid_auth};
        undefined ->
            {error, auth_not_configured}
    end.

-doc """
Extra origins (`~"https://ops.example.com"`) whose POST requests are accepted
when the browser sends no `Sec-Fetch-Site` header. Empty by default; see
`m:nova_liveboard_csrf`.
""".
-spec trusted_origins() -> [binary()].
trusted_origins() ->
    case application:get_env(nova_liveboard, trusted_origins, []) of
        Origins when is_list(Origins) -> [Origin || Origin <- Origins, is_binary(Origin)];
        _ -> []
    end.

-doc """
How request paths, port names and child ids are masked before they are shown;
see `m:nova_liveboard_redact`. The `redact` env is `standard`, `none`, `all`
or `{Module, Function}`. Anything else is treated as `all`.
""".
-spec redact() -> standard | none | all | {callback, {module(), atom()}}.
redact() ->
    case application:get_env(nova_liveboard, redact, standard) of
        standard ->
            standard;
        none ->
            none;
        {Module, Function} when is_atom(Module), is_atom(Function) ->
            {callback, {Module, Function}};
        _ ->
            all
    end.

-spec valid(atom()) -> boolean().
valid(Key) ->
    case application:get_env(nova_liveboard, Key) of
        undefined -> true;
        {ok, Value} -> valid(Key, Value)
    end.

-spec valid(atom(), term()) -> boolean().
valid(prefix, Value) ->
    mount_path(Value);
valid(Limit, Value) when Limit =:= max_streams; Limit =:= max_streams_per_client ->
    is_integer(Value) andalso Value >= 0;
valid(redact, {Module, Function}) when is_atom(Module), is_atom(Function) ->
    code:ensure_loaded(Module) =:= {module, Module} andalso
        erlang:function_exported(Module, Function, 2);
valid(redact, Value) ->
    lists:member(Value, [standard, none, all]);
valid(trusted_origins, Value) ->
    origins(Value);
valid(_PositiveInteger, Value) ->
    is_integer(Value) andalso Value > 0.

-spec accepted(atom()) -> binary().
accepted(prefix) ->
    ~"a string or binary that is empty or starts with \"/\" and does not end with \"/\"";
accepted(Limit) when Limit =:= max_streams; Limit =:= max_streams_per_client ->
    ~"a non-negative integer";
accepted(redact) ->
    ~"standard, none, all or {Module, Function} where Module:Function/2 is exported";
accepted(trusted_origins) ->
    ~"a list of binaries, each a scheme and a host such as <<\"https://ops.example.com\">>";
accepted(_PositiveInteger) ->
    ~"a positive integer".

-spec mount_path(term()) -> boolean().
mount_path(Value) ->
    case text(Value) of
        {ok, ~""} -> true;
        {ok, <<"/", _/binary>> = Path} -> binary:last(Path) =/= $/;
        _ -> false
    end.

-spec text(term()) -> {ok, binary()} | error.
text(Binary) when is_binary(Binary) ->
    {ok, Binary};
text(String) when is_list(String) ->
    case characters(String, []) of
        {ok, Characters} ->
            case unicode:characters_to_binary(Characters) of
                Binary when is_binary(Binary) -> {ok, Binary};
                _ -> error
            end;
        error ->
            error
    end;
text(_) ->
    error.

-spec characters(term(), [char()]) -> {ok, [char()]} | error.
characters([], Characters) ->
    {ok, lists:reverse(Characters)};
characters([Character | Rest], Characters) when
    is_integer(Character), Character >= 0, Character =< 16#10FFFF
->
    characters(Rest, [Character | Characters]);
characters(_, _Characters) ->
    error.

-spec origins(term()) -> boolean().
origins([]) -> true;
origins([Origin | Rest]) -> origin(Origin) andalso origins(Rest);
origins(_) -> false.

-spec origin(term()) -> boolean().
origin(<<"http://", Host/binary>>) -> host(Host);
origin(<<"https://", Host/binary>>) -> host(Host);
origin(_) -> false.

-spec host(binary()) -> boolean().
host(Host) ->
    Host =/= ~"" andalso binary:match(Host, ~"/") =:= nomatch.
