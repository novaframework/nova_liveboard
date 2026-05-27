-module(nova_liveboard_router).
-behaviour(nova_router).

-export([routes/1]).

%% All pages, the per-region SSE streams, the request-trace actions and the
%% static assets run on Nova's own listener under the configured prefix. The
%% /sse/:page route returns {stream, ...}, held open by nova_liveboard_sse
%% (see that module + novaframework/nova#387).
routes(_Env) ->
    [
        #{
            prefix => binary_to_list(nova_liveboard:prefix()),
            security => false,
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
                {"/assets/[...]", "static/assets"}
            ]
        }
    ].
