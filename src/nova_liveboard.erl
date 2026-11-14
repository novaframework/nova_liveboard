-module(nova_liveboard).
-moduledoc """
Configuration helpers for the liveboard.

All settings live under the `nova_liveboard` application env:

- `prefix` (default `"/liveboard"`) - the path the dashboard mounts on.
- `refresh_ms` (default `2000`) - how often the polled SSE streams repaint.
- `request_buffer` (default `200`) - how many recent requests the tracer keeps.
- `auth` (no default) - who may use the liveboard, see `auth/0`.
""".

-export([prefix/0, refresh_ms/0, request_buffer/0, auth/0]).

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
    application:get_env(nova_liveboard, refresh_ms, 2000).

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
