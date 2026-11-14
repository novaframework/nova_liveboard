-module(nova_liveboard).
-moduledoc """
Configuration helpers for the liveboard.

All settings live under the `nova_liveboard` application env:

- `prefix` (default `"/liveboard"`) - the path the dashboard mounts on.
- `refresh_ms` (default `2000`) - how often the polled SSE streams repaint.
- `request_buffer` (default `200`) - how many recent requests the tracer keeps.
- `max_streams` (default `50`) - how many live streams may be open at once.
- `stream_lifetime_ms` (default `300000`) - how long one live stream may stay
  open before the browser has to reconnect.
- `auth` (no default) - who may use the liveboard, see `auth/0`.
- `trusted_origins` (default `[]`) - see `trusted_origins/0`.
""".

-export([
    prefix/0,
    refresh_ms/0,
    request_buffer/0,
    max_streams/0,
    stream_lifetime_ms/0,
    auth/0,
    trusted_origins/0
]).

-type auth() :: none | {module(), atom()}.
-type auth_error() ::
    auth_not_configured
    | {invalid_auth, term()}
    | {auth_callback_not_exported, {module(), atom(), 1}}.

-export_type([auth/0, auth_error/0]).

-doc "The mount path, always as a binary with a leading slash.".
-spec prefix() -> binary().
prefix() ->
    case application:get_env(nova_liveboard, prefix, ~"/liveboard") of
        P when is_binary(P) -> P;
        P when is_list(P) -> list_to_binary(P)
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
    application:get_env(nova_liveboard, request_buffer, 200).

-doc """
Who may use the liveboard. There is no default: the host must set `auth` to

- `{Module, Function}`, a Nova security callback `Module:Function(Req)` that is
  put on every liveboard route, or
- `none`, the explicit opt-out for a liveboard that is protected some other
  way.

Anything else is an error and the router refuses to build its routes.
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
        {ok, Other} ->
            {error, {invalid_auth, Other}};
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
