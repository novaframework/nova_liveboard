-module(nova_liveboard_trace_plugin_tests).
-include_lib("eunit/include/eunit.hrl").

plugin_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun captures_request_summary/1,
        fun resolves_handler_from_fun/1,
        fun resolves_handler_from_tuple/1,
        fun skips_own_paths/1,
        fun skips_only_whole_segments_of_the_prefix/1,
        fun skips_what_nova_routed_to_the_liveboard/1,
        fun a_root_mount_does_not_hide_the_host/1
    ]}.

setup() ->
    application:set_env(nova_liveboard, request_buffer, 50),
    {ok, Pid} = nova_liveboard_tracer:start_link(),
    Pid.

cleanup(Pid) ->
    gen_server:stop(Pid).

captures_request_summary(_) ->
    ?_test(begin
        Req0 = #{method => ~"POST", path => ~"/api/widgets", qs => ~""},
        Env = #{callback => fun lists:reverse/1},
        {ok, Req1, undefined} = nova_liveboard_trace_plugin:pre_request(Req0, Env, #{}, undefined),
        ?assert(map_size(Req1) > map_size(Req0)),
        {ok, _Req2, undefined} = nova_liveboard_trace_plugin:post_request(
            Req1#{resp_status_code => 201}, Env, #{}, undefined
        ),
        [R | _] = nova_liveboard_tracer:recent(),
        ?assertEqual(~"POST", maps:get(method, R)),
        ?assertEqual(~"/api/widgets", maps:get(path, R)),
        ?assertEqual(201, maps:get(status, R)),
        ?assert(maps:get(duration_us, R) >= 0),
        ?assert(maps:get(reductions, R) >= 0),
        ?assertEqual(0, maps:get(spawned, R))
    end).

resolves_handler_from_fun(_) ->
    ?_test(begin
        record(#{callback => fun lists:reverse/1}),
        [R | _] = nova_liveboard_tracer:recent(),
        ?assertEqual(~"lists:reverse/1", maps:get(handler, R))
    end).

resolves_handler_from_tuple(_) ->
    ?_test(begin
        record(#{callback => {my_mod, my_fun}}),
        [R | _] = nova_liveboard_tracer:recent(),
        ?assertEqual(~"my_mod:my_fun", maps:get(handler, R))
    end).

skips_own_paths(_) ->
    ?_test(begin
        Req0 = #{method => ~"GET", path => ~"/liveboard/processes", qs => ~""},
        {ok, Req1, undefined} = nova_liveboard_trace_plugin:pre_request(
            Req0, #{callback => fun lists:reverse/1}, #{}, undefined
        ),
        %% own path => no marker added, request untouched
        ?assertEqual(Req0, Req1),
        {ok, _, undefined} = nova_liveboard_trace_plugin:post_request(Req1, #{}, #{}, undefined),
        ?assertEqual([], nova_liveboard_tracer:recent())
    end).

skips_only_whole_segments_of_the_prefix(_) ->
    ?_test(begin
        Own = [~"/liveboard", ~"/liveboard/", ~"/liveboard/sse/ets", ~"/liveboard//x"],
        Host = [
            ~"/liveboardXYZ",
            ~"/liveboard-status",
            ~"/liveboard.json",
            ~"/liveboards/1",
            ~"/liveboar",
            ~"/api/liveboard",
            ~"/api/liveboard/x",
            ~"/",
            ~"liveboard"
        ],
        ?assertEqual([], [Path || Path <- Own, captured(Path, #{})]),
        ?assertEqual(Host, [Path || Path <- Host, captured(Path, #{})]),
        ?assertEqual(lists:reverse(Host), [maps:get(path, R) || R <- nova_liveboard_tracer:recent()])
    end).

%% Nova puts the application a route belongs to in the environment, which
%% holds whatever prefix the liveboard ends up mounted on.
skips_what_nova_routed_to_the_liveboard(_) ->
    ?_test(begin
        ?assertNot(captured(~"/ops/liveboard/ets", #{app => nova_liveboard})),
        ?assert(captured(~"/ops/liveboard/ets", #{app => my_app})),
        ?assertNot(captured(~"/liveboard/ets", #{app => my_app}))
    end).

a_root_mount_does_not_hide_the_host(_) ->
    {setup, fun() -> application:set_env(nova_liveboard, prefix, ~"") end,
        fun(_) -> application:set_env(nova_liveboard, prefix, "/liveboard") end,
        ?_test(begin
            ?assert(captured(~"/api/widgets", #{app => my_app})),
            ?assert(captured(~"/", #{app => my_app})),
            ?assertNot(captured(~"/ets", #{app => nova_liveboard}))
        end)}.

%% Whether a request for `Path` is marked for the request feed.
captured(Path, Env) ->
    Req0 = #{method => ~"GET", path => Path, qs => ~""},
    {ok, Req1, undefined} = nova_liveboard_trace_plugin:pre_request(Req0, Env, #{}, undefined),
    {ok, _, undefined} = nova_liveboard_trace_plugin:post_request(
        Req1#{resp_status_code => 200}, Env, #{}, undefined
    ),
    Req1 =/= Req0.

record(Env) ->
    Req0 = #{method => ~"GET", path => ~"/x", qs => ~""},
    {ok, Req1, _} = nova_liveboard_trace_plugin:pre_request(Req0, Env, #{}, undefined),
    {ok, _, _} = nova_liveboard_trace_plugin:post_request(
        Req1#{resp_status_code => 200}, Env, #{}, undefined
    ).
