-module(nova_liveboard_app).
-moduledoc """
Application entry point.

Starts the supervision tree (the request tracer) and registers the
`{stream, ...}` Datastar SSE return-handler with Nova. The request-tracing
plugin is *not* auto-registered: it is a global Nova plugin, so the host wires
it into its own `{nova, [{plugins, ...}]}` config (see the README). The
dashboard's pages work either way; only the Requests feed needs the plugin.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = nova_liveboard_sup:start_link(),
    ok = nova_liveboard_sse:register(),
    {ok, Sup}.

stop(_State) ->
    ok.
