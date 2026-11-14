-module(nova_liveboard_router).
-behaviour(nova_router).

-include_lib("kernel/include/logger.hrl").

-export([routes/1]).

%% All pages, the per-region SSE streams, the request-trace actions and the
%% static assets run on Nova's own listener under the configured prefix. The
%% /sse/:page route returns {stream, ...}, held open by nova_liveboard_sse
%% (see that module + novaframework/nova#387). Assets are a closed set, not a
%% wildcard directory: no request data is ever joined onto a path.
routes(_Env) ->
    [
        #{
            prefix => binary_to_list(nova_liveboard:prefix()),
            security => security(),
            routes => [
                {"/", fun nova_liveboard_page_controller:index/1, #{methods => [get]}},
                {"/processes", fun nova_liveboard_page_controller:processes/1, #{methods => [get]}},
                {"/ets", fun nova_liveboard_page_controller:ets/1, #{methods => [get]}},
                {"/applications", fun nova_liveboard_page_controller:applications/1, #{
                    methods => [get]
                }},
                {"/ports", fun nova_liveboard_page_controller:ports/1, #{methods => [get]}},
                {"/supervisors", fun nova_liveboard_page_controller:supervisors/1, #{
                    methods => [get]
                }},
                {"/metrics", fun nova_liveboard_page_controller:metrics/1, #{methods => [get]}},
                {"/database", fun nova_liveboard_page_controller:database/1, #{methods => [get]}},
                {"/schemas", fun nova_liveboard_page_controller:schemas/1, #{methods => [get]}},
                {"/requests", fun nova_liveboard_page_controller:requests/1, #{methods => [get]}},
                {"/requests/trace/start", fun nova_liveboard_action_controller:trace_start/1, #{
                    methods => [post]
                }},
                {"/requests/trace/stop", fun nova_liveboard_action_controller:trace_stop/1, #{
                    methods => [post]
                }},
                {"/requests/clear", fun nova_liveboard_action_controller:clear/1, #{
                    methods => [post]
                }},
                {"/requests/:id", fun nova_liveboard_page_controller:request_show/1, #{
                    methods => [get]
                }},
                {"/sse/:page", fun nova_liveboard_sse:stream/1, #{methods => [get]}},
                {"/heartbeat", fun(_) -> {status, 200} end, #{methods => [get]}},
                {"/assets/css/app.css", fun nova_liveboard_asset_controller:stylesheet/1, #{
                    methods => [get]
                }},
                {"/assets/js/datastar.js", fun nova_liveboard_asset_controller:script/1, #{
                    methods => [get]
                }},
                {"/assets/fonts/:font", fun nova_liveboard_asset_controller:font/1, #{
                    methods => [get]
                }}
            ]
        }
    ].

%% The liveboard shows the node's processes, tables, ports and request
%% traffic, so it never mounts without the host having decided who may reach
%% it.
security() ->
    case nova_liveboard:auth() of
        {ok, none} ->
            ?LOG_WARNING(#{
                msg => ~"nova_liveboard_mounted_without_auth",
                prefix => nova_liveboard:prefix()
            }),
            false;
        {ok, {Module, Function}} ->
            fun Module:Function/1;
        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => ~"nova_liveboard_refusing_to_mount",
                reason => Reason,
                fix => ~"set {auth, {Module, Function}} or {auth, none} in the nova_liveboard env"
            }),
            error({nova_liveboard_refusing_to_mount, Reason})
    end.
