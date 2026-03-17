-module(nova_liveboard).

-export([setup/0, setup/1]).

-spec setup() -> ok.
setup() ->
    setup(#{}).

-spec setup(Opts :: map()) -> ok.
setup(Opts) ->
    Prefix = maps:get(prefix, Opts, "/liveboard"),
    Routes = [
        #{
            prefix => Prefix,
            security => false,
            routes => [
                {"/", fun nova_liveboard_page_controller:index/1, #{methods => [get]}},
                {"/live", nova_liveboard_ws, #{protocol => ws}},
                {"/:page", fun nova_liveboard_page_controller:index/1, #{methods => [get]}}
            ]
        },
        #{
            prefix => "",
            security => false,
            routes => [
                {"/assets/[...]", "static/assets"}
            ]
        }
    ],
    nova_router:add_routes(nova_liveboard, Routes).
