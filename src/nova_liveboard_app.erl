-module(nova_liveboard_app).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    arizona_nova:register_views(nova_liveboard, fun nova_liveboard_controller:resolve_view/1),
    {ok, self()}.

stop(_State) ->
    ok.
