-module(nova_liveboard_sup).
-moduledoc """
Top supervisor: owns the request tracer and the poller that feeds the live
streams. The poller subscribes to the tracer, so it is restarted with it.
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{
            id => nova_liveboard_tracer,
            start => {nova_liveboard_tracer, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker
        },
        #{
            id => nova_liveboard_poller,
            start => {nova_liveboard_poller, start_link, []}
        }
    ],
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, Children}}.
