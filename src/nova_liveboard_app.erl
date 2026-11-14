-module(nova_liveboard_app).
-moduledoc """
Application entry point.

Checks the configuration first (`nova_liveboard:validate/0`) and refuses to
start with `{invalid_config, [{Key, Accepted}]}` when a setting is not
accepted. Then starts the supervision tree (the request tracer and the stream
poller) and registers the `{stream, ...}` Datastar SSE return-handler with Nova. The
request-tracing plugin is *not* auto-registered: it is a global Nova plugin,
so the host wires it into its own `{nova, [{plugins, ...}]}` config (see the
README). The dashboard's pages work either way; only the Requests feed needs
the plugin.
""".
-behaviour(application).

-include_lib("kernel/include/logger.hrl").

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case nova_liveboard:validate() of
        ok ->
            {ok, Sup} = nova_liveboard_sup:start_link(),
            ok = nova_liveboard_sse:register(),
            {ok, Sup};
        {error, Invalid} ->
            ?LOG_ERROR(#{
                msg => ~"nova_liveboard_invalid_config",
                accepted => maps:from_list(Invalid)
            }),
            {error, {invalid_config, Invalid}}
    end.

stop(_State) ->
    ok.
