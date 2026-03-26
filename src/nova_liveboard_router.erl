-module(nova_liveboard_router).
-behaviour(nova_router).

-export([routes/1]).

routes(_Env) ->
    [
        #{
            prefix => nova_liveboard:prefix(),
            security => false,
            routes => [
                {~"/", fun nova_liveboard_controller:index/1, #{methods => [get]}},
                {~"/:page", fun nova_liveboard_controller:index/1, #{methods => [get]}},
                {"/assets/[...]", "static/assets"}
            ]
        }
    ].
