-module(nova_liveboard_test_host_router).
-behaviour(nova_router).

-export([routes/1]).

-spec routes(atom()) -> [map()].
routes(_Env) ->
    [].
