-module(nova_liveboard_tracer_tests).
-include_lib("eunit/include/eunit.hrl").

tracer_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun ring_buffer_caps/1,
        fun get_and_recent/1,
        fun active_flag/1,
        fun subscribe_notify/1,
        fun deep_trace_builds_tree/1,
        fun arm_then_disarm/1,
        fun clear_empties/1
    ]}.

setup() ->
    application:set_env(nova_liveboard, request_buffer, 3),
    {ok, Pid} = nova_liveboard_tracer:start_link(),
    Pid.

cleanup(Pid) ->
    gen_server:stop(Pid).

ring_buffer_caps(_) ->
    ?_test(begin
        [nova_liveboard_tracer:finalize(I, summary(I)) || I <- ids(5)],
        Recent = nova_liveboard_tracer:recent(),
        ?assertEqual(3, length(Recent)),
        %% newest first
        ?assertEqual(~"5", maps:get(id, hd(Recent)))
    end).

get_and_recent(_) ->
    ?_test(begin
        nova_liveboard_tracer:finalize(~"g1", summary(~"g1")),
        R = nova_liveboard_tracer:get(~"g1"),
        ?assertEqual(~"g1", maps:get(id, R)),
        ?assertEqual(0, maps:get(spawned, R)),
        ?assertEqual(undefined, nova_liveboard_tracer:get(~"missing"))
    end).

active_flag(_) ->
    ?_test(begin
        ?assertEqual(false, nova_liveboard_tracer:active()),
        nova_liveboard_tracer:finalize(~"a1", summary(~"a1")),
        ?assertEqual(true, nova_liveboard_tracer:active())
    end).

subscribe_notify(_) ->
    ?_test(begin
        ok = nova_liveboard_tracer:subscribe(),
        nova_liveboard_tracer:finalize(~"s1", summary(~"s1")),
        receive
            {nova_liveboard_request, R} -> ?assertEqual(~"s1", maps:get(id, R))
        after 1000 -> ?assert(false)
        end
    end).

deep_trace_builds_tree(_) ->
    ?_test(begin
        nova_liveboard_tracer:start_trace(2),
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"r1", self())),
        Child = spawn(fun() -> ok end),
        Grand = spawn(fun() -> ok end),
        %% root spawns Child, then Child spawns Grand (set_on_spawn lineage)
        nova_liveboard_tracer ! {trace, self(), spawn, Child, {worker, run, []}},
        nova_liveboard_tracer ! {trace, Child, spawn, Grand, {helper, go, [a, b]}},
        nova_liveboard_tracer:finalize(~"r1", summary(~"r1")),
        [R | _] = nova_liveboard_tracer:recent(),
        ?assertEqual(2, maps:get(spawned, R)),
        Tree = maps:get(spawned_tree, R),
        ?assertEqual([~"worker:run/0", ~"helper:go/2"], [maps:get(mfa, N) || N <- Tree]),
        %% depth grows down the lineage
        ?assertEqual([1, 2], [maps:get(depth, N) || N <- Tree])
    end).

arm_then_disarm(_) ->
    ?_test(begin
        nova_liveboard_tracer:start_trace(2),
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"a", self())),
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"b", self())),
        %% armed count exhausted
        ?assertEqual(no_trace, nova_liveboard_tracer:maybe_arm(~"c", self())),
        ?assertEqual(#{armed => false, remaining => 0}, nova_liveboard_tracer:trace_state()),
        nova_liveboard_tracer:start_trace(5),
        nova_liveboard_tracer:stop_trace(),
        ?assertEqual(#{armed => false, remaining => 0}, nova_liveboard_tracer:trace_state())
    end).

clear_empties(_) ->
    ?_test(begin
        nova_liveboard_tracer:finalize(~"c1", summary(~"c1")),
        ?assertEqual(1, length(nova_liveboard_tracer:recent())),
        nova_liveboard_tracer:clear(),
        ?assertEqual([], nova_liveboard_tracer:recent())
    end).

%% helpers

ids(N) -> [integer_to_binary(I) || I <- lists:seq(1, N)].

summary(Id) ->
    #{
        id => Id,
        method => ~"GET",
        path => ~"/x",
        handler => ~"m:f/1",
        status => 200,
        duration_us => 10,
        reductions => 5,
        mem => 100,
        ts => 0
    }.
