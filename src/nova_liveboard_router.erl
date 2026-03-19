-module(nova_liveboard_router).
-behaviour(nova_router).

-export([routes/1]).

routes(_Environment) ->
    [
        #{
            prefix => "",
            security => false,
            routes => [
                {"/", fun nova_liveboard_page_controller:index/1, #{methods => [get]}},
                {"/:page", fun nova_liveboard_page_controller:index/1, #{methods => [get]}},
                {"/live", nova_liveboard_ws, #{protocol => ws}},
                {"/assets/[...]", "static/assets"}
            ]
        }
    ].
