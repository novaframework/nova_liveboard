-module(nova_liveboard_action_controller_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, nova_liveboard_action_controller).

action_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun start_arms_the_tracer_and_patches_the_toolbar/0,
        fun stop_disarms_the_tracer/0,
        fun clear_empties_the_feed/0,
        fun unverified_request_never_reaches_the_tracer/0
    ]}.

setup() ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, critical),
    application:set_env(nova_liveboard, prefix, ~"/liveboard"),
    {ok, Tracer} = nova_liveboard_tracer:start_link(),
    {Tracer, Level}.

cleanup({Tracer, Level}) ->
    gen_server:stop(Tracer),
    application:set_env(nova_liveboard, prefix, "/liveboard"),
    ok = logger:set_primary_config(level, Level).

same_origin() ->
    Token = binary:copy(~"t", 43),
    #{
        headers => #{
            ~"host" => ~"board.test",
            ~"sec-fetch-site" => ~"same-origin",
            ~"cookie" => <<"nova_liveboard_csrf=", Token/binary>>,
            ~"x-csrf-token" => Token
        }
    }.

start_arms_the_tracer_and_patches_the_toolbar() ->
    {status, 200, Headers, Body} = ?M:trace_start(same_origin()),
    ?assertEqual(~"text/event-stream", maps:get(~"content-type", Headers)),
    ?assertEqual(#{armed => true, remaining => 10}, nova_liveboard_tracer:trace_state()),
    ?assertNotEqual(nomatch, binary:match(Body, ~"data: selector #req-toolbar")),
    ?assertNotEqual(nomatch, binary:match(Body, ~"deep trace armed")).

stop_disarms_the_tracer() ->
    nova_liveboard_tracer:start_trace(5),
    {status, 200, _Headers, Body} = ?M:trace_stop(same_origin()),
    ?assertEqual(#{armed => false, remaining => 0}, nova_liveboard_tracer:trace_state()),
    ?assertNotEqual(nomatch, binary:match(Body, ~"deep trace off")).

clear_empties_the_feed() ->
    capture_one_request(),
    {status, 200, _Headers, Body} = ?M:clear(same_origin()),
    ?assertEqual([], nova_liveboard_tracer:recent()),
    ?assertNotEqual(nomatch, binary:match(Body, ~"data: selector #req-feed")).

unverified_request_never_reaches_the_tracer() ->
    capture_one_request(),
    #{headers := Headers} = same_origin(),
    Forgeries = [
        #{},
        #{headers => #{}},
        #{headers => maps:remove(~"x-csrf-token", Headers)},
        #{headers => maps:remove(~"cookie", Headers)},
        #{headers => Headers#{~"sec-fetch-site" => ~"cross-site"}},
        #{headers => Headers#{~"x-csrf-token" => binary:copy(~"u", 43)}}
    ],
    [
        ?assertEqual({status, 403}, Action(Req))
     || Req <- Forgeries,
        Action <- [fun ?M:trace_start/1, fun ?M:trace_stop/1, fun ?M:clear/1]
    ],
    ?assertEqual(#{armed => false, remaining => 0}, nova_liveboard_tracer:trace_state()),
    ?assertEqual(1, length(nova_liveboard_tracer:recent())).

capture_one_request() ->
    nova_liveboard_tracer:finalize(~"0123456789ab", #{
        id => ~"0123456789ab",
        method => ~"GET",
        path => ~"/api/widgets",
        handler => ~"widgets:index/1",
        status => 200,
        duration_us => 10,
        reductions => 20,
        mem => 30,
        ts => 0
    }).
