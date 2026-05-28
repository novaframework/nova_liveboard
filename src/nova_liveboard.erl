-module(nova_liveboard).
-moduledoc """
Configuration helpers for the liveboard.

All settings live under the `nova_liveboard` application env:

- `prefix` (default `"/liveboard"`) - the path the dashboard mounts on.
- `refresh_ms` (default `2000`) - how often the polled SSE streams repaint.
- `request_buffer` (default `200`) - how many recent requests the tracer keeps.
""".

-export([prefix/0, refresh_ms/0, request_buffer/0]).

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
