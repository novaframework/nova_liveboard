-module(nova_liveboard_auth_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SERVER, nova_liveboard_test_server).
-define(AUTH, {nova_liveboard_test_auth, operators_only}).

%% ---------------------------------------------------------------------------
%% route build
%% ---------------------------------------------------------------------------

config_test_() ->
    {foreach, fun quiet/0, fun restore/1, [
        fun missing_auth_refuses_to_mount/0,
        fun invalid_auth_refuses_to_mount/0,
        fun unexported_callback_refuses_to_mount/0,
        fun none_is_an_explicit_opt_out/0,
        fun callback_secures_every_route/0
    ]}.

quiet() ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, critical),
    application:unset_env(nova_liveboard, auth),
    Level.

restore(Level) ->
    application:unset_env(nova_liveboard, auth),
    ok = logger:set_primary_config(level, Level).

missing_auth_refuses_to_mount() ->
    ?assertEqual({error, auth_not_configured}, nova_liveboard:auth()),
    ?assertError(
        {nova_liveboard_refusing_to_mount, auth_not_configured},
        nova_liveboard_router:routes(dev)
    ).

invalid_auth_refuses_to_mount() ->
    [
        begin
            application:set_env(nova_liveboard, auth, Value),
            ?assertEqual({Value, {error, invalid_auth}}, {Value, nova_liveboard:auth()}),
            ?assertError(
                {nova_liveboard_refusing_to_mount, invalid_auth},
                nova_liveboard_router:routes(dev)
            )
        end
     || Value <- [
            false,
            true,
            undefined,
            ~"none",
            "none",
            fun erlang:is_map/1,
            {a, b, c},
            [],
            {basic, ~"operator", ~"correct horse"}
        ]
    ].

unexported_callback_refuses_to_mount() ->
    [
        begin
            application:set_env(nova_liveboard, auth, {Module, Function}),
            ?assertError(
                {nova_liveboard_refusing_to_mount,
                    {auth_callback_not_exported, {Module, Function, 1}}},
                nova_liveboard_router:routes(dev)
            )
        end
     || {Module, Function} <- [
            {nova_liveboard_no_such_module, check},
            {nova_liveboard_test_auth, no_such_function},
            {nova_liveboard_test_auth, not_a_callback}
        ]
    ].

none_is_an_explicit_opt_out() ->
    application:set_env(nova_liveboard, auth, none),
    ?assertEqual(
        [false], [maps:get(security, Group) || Group <- nova_liveboard_router:routes(dev)]
    ).

callback_secures_every_route() ->
    application:set_env(nova_liveboard, auth, ?AUTH),
    Groups = nova_liveboard_router:routes(dev),
    ?assertEqual(
        [fun nova_liveboard_test_auth:operators_only/1],
        [maps:get(security, Group) || Group <- Groups]
    ),
    ?assertEqual(1, length(Groups)).

%% ---------------------------------------------------------------------------
%% mounted in Nova
%% ---------------------------------------------------------------------------

nova_refuses_to_start_without_auth_test() ->
    ?assertError(
        {nova_did_not_start, _},
        ?SERVER:start([{prefix, ~"/liveboard"}])
    ).

mounted_test_() ->
    {setup,
        fun() ->
            ?SERVER:start([
                {prefix, ~"/liveboard"},
                {auth, ?AUTH},
                {test_login, {~"operator", ~"correct horse"}}
            ])
        end,
        fun ?SERVER:stop/1, fun(Server) ->
            [
                {"every route asks for credentials", fun() -> anonymous_is_rejected(Server) end},
                {"wrong credentials are rejected", fun() -> wrong_login_is_rejected(Server) end},
                {"valid credentials get through", fun() -> valid_login_is_accepted(Server) end}
            ]
        end}.

anonymous_is_rejected(Server) ->
    nova_liveboard_tracer:start_trace(0),
    [
        begin
            Response = ?SERVER:request(Server, Line, [{~"content-length", ~"0"}]),
            ?assertEqual({Line, 401}, {Line, ?SERVER:status(Response)}),
            ?assertEqual(
                ~"Basic realm=\"liveboard\"", ?SERVER:header(~"www-authenticate", Response)
            ),
            ?assertEqual(nomatch, binary:match(?SERVER:body(Response), ~"liveboard</b>"))
        end
     || Line <- request_lines()
    ],
    ?assertEqual(#{armed => false, remaining => 0}, nova_liveboard_tracer:trace_state()).

wrong_login_is_rejected(Server) ->
    [
        ?assertEqual(
            401,
            ?SERVER:status(
                ?SERVER:request(Server, ~"GET /liveboard/ HTTP/1.1", [{~"authorization", Value}])
            )
        )
     || Value <- [
            basic(~"operator", ~"wrong"),
            basic(~"someone", ~"correct horse"),
            ~"Basic",
            ~"Basic !!!",
            ~"Bearer abc"
        ]
    ].

valid_login_is_accepted(Server) ->
    Login = [{~"authorization", basic(~"operator", ~"correct horse")}],
    Page = ?SERVER:request(Server, ~"GET /liveboard/processes HTTP/1.1", Login),
    ?assertEqual(200, ?SERVER:status(Page)),
    ?assertNotEqual(nomatch, binary:match(?SERVER:body(Page), ~"liveboard</b>")),
    Asset = ?SERVER:request(Server, ~"GET /liveboard/assets/js/datastar.js HTTP/1.1", Login),
    ?assertEqual(200, ?SERVER:status(Asset)).

request_lines() ->
    [
        ~"GET /liveboard/ HTTP/1.1",
        ~"GET /liveboard/processes HTTP/1.1",
        ~"GET /liveboard/ets HTTP/1.1",
        ~"GET /liveboard/applications HTTP/1.1",
        ~"GET /liveboard/ports HTTP/1.1",
        ~"GET /liveboard/supervisors HTTP/1.1",
        ~"GET /liveboard/metrics HTTP/1.1",
        ~"GET /liveboard/database HTTP/1.1",
        ~"GET /liveboard/schemas HTTP/1.1",
        ~"GET /liveboard/requests HTTP/1.1",
        ~"GET /liveboard/requests/0123456789ab HTTP/1.1",
        ~"GET /liveboard/sse/vitals HTTP/1.1",
        ~"GET /liveboard/sse/processes HTTP/1.1",
        ~"GET /liveboard/sse/requests HTTP/1.1",
        ~"GET /liveboard/heartbeat HTTP/1.1",
        ~"GET /liveboard/assets/js/datastar.js HTTP/1.1",
        ~"GET /liveboard/assets/css/app.css HTTP/1.1",
        ~"GET /liveboard/assets/fonts/ibm-plex-mono-latin-400-normal.woff2 HTTP/1.1",
        ~"POST /liveboard/requests/trace/start HTTP/1.1",
        ~"POST /liveboard/requests/trace/stop HTTP/1.1",
        ~"POST /liveboard/requests/clear HTTP/1.1"
    ].

basic(User, Password) ->
    <<"Basic ", (base64:encode(<<User/binary, ":", Password/binary>>))/binary>>.
