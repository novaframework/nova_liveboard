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
        fun clear_empties/1,
        fun finalize_forgets_the_trace/1,
        fun a_request_that_dies_is_forgotten/1
    ]}.

capped_test_() ->
    {foreach, fun() -> setup(#{max_traces => 2, max_pids => 4}) end, fun cleanup/1, [
        fun in_flight_traces_are_capped/1,
        fun followed_processes_are_capped/1
    ]}.

swept_test_() ->
    {foreach, fun() -> setup(#{max_age_ms => 150, sweep_ms => 20}) end, fun cleanup/1, [
        fun a_request_that_never_ends_is_swept/1
    ]}.

setup() ->
    setup(#{}).

setup(Limits) ->
    application:set_env(nova_liveboard, request_buffer, 3),
    {ok, Pid} = nova_liveboard_tracer:start_link(Limits),
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
        #{id := Id, spawned := Spawned} = nova_liveboard_tracer:get(~"g1"),
        ?assertEqual(~"g1", Id),
        ?assertEqual(0, Spawned),
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

finalize_forgets_the_trace(_) ->
    ?_test(begin
        nova_liveboard_tracer:start_trace(1),
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"f1", self())),
        Child = spawn(fun() -> ok end),
        nova_liveboard_tracer ! {trace, self(), spawn, Child, {worker, run, []}},
        ?assertEqual(#{traces => 1, pids => 2}, nova_liveboard_tracer:in_flight()),
        nova_liveboard_tracer:finalize(~"f1", summary(~"f1")),
        ?assertEqual(#{traces => 0, pids => 0}, nova_liveboard_tracer:in_flight()),
        ?assertEqual(1, maps:get(spawned, request(~"f1")))
    end).

%% A handler crash, a websocket upgrade and a client that goes away all end
%% the request process without `finalize/2`.
a_request_that_dies_is_forgotten(_) ->
    ?_test(begin
        nova_liveboard_tracer:start_trace(3),
        Requests = [request_process(Id, Exit) || {Id, Exit} <- [{~"d1", normal}, {~"d2", crashed}]],
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"alive", self())),
        ?assertEqual(#{traces => 3, pids => 5}, nova_liveboard_tracer:in_flight()),
        [Request ! stop || Request <- Requests],
        ok = wait_until(fun() ->
            nova_liveboard_tracer:in_flight() =:= #{traces => 1, pids => 1}
        end),
        nova_liveboard_tracer:finalize(~"alive", summary(~"alive")),
        ?assertEqual(#{traces => 0, pids => 0}, nova_liveboard_tracer:in_flight()),
        ?assertEqual([~"alive"], [maps:get(id, R) || R <- nova_liveboard_tracer:recent()])
    end).

%% A request that stays open (a stream, a long poll) is dropped by age and is
%% no longer traced, so it stops reporting what it spawns.
a_request_that_never_ends_is_swept(_) ->
    ?_test(begin
        nova_liveboard_tracer:start_trace(2),
        Stuck = request_process(~"stuck", normal),
        ?assertEqual(#{traces => 1, pids => 2}, nova_liveboard_tracer:in_flight()),
        ?assertEqual([procs, set_on_spawn], trace_flags(Stuck)),
        ok = wait_until(fun() ->
            nova_liveboard_tracer:in_flight() =:= #{traces => 0, pids => 0}
        end),
        ?assert(is_process_alive(Stuck)),
        ?assertEqual([], trace_flags(Stuck)),
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"next", self())),
        nova_liveboard_tracer:finalize(~"next", summary(~"next")),
        Stuck ! stop,
        ?assertEqual([~"next"], [maps:get(id, R) || R <- nova_liveboard_tracer:recent()])
    end).

in_flight_traces_are_capped(_) ->
    ?_test(begin
        nova_liveboard_tracer:start_trace(5),
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"c1", self())),
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"c2", self())),
        ?assertEqual(no_trace, nova_liveboard_tracer:maybe_arm(~"c3", self())),
        ?assertEqual(#{armed => true, remaining => 3}, nova_liveboard_tracer:trace_state()),
        nova_liveboard_tracer:finalize(~"c1", summary(~"c1")),
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"c4", self())),
        ?assertEqual(2, maps:get(traces, nova_liveboard_tracer:in_flight()))
    end).

followed_processes_are_capped(_) ->
    ?_test(begin
        nova_liveboard_tracer:start_trace(1),
        ?assertEqual(trace, nova_liveboard_tracer:maybe_arm(~"p1", self())),
        Children = [spawn(fun() -> ok end) || _ <- lists:seq(1, 10)],
        [
            nova_liveboard_tracer ! {trace, self(), spawn, Child, {worker, run, []}}
         || Child <- Children
        ],
        ?assertEqual(#{traces => 1, pids => 4}, nova_liveboard_tracer:in_flight()),
        nova_liveboard_tracer:finalize(~"p1", summary(~"p1")),
        ?assertEqual(3, maps:get(spawned, request(~"p1"))),
        ?assertEqual(#{traces => 0, pids => 0}, nova_liveboard_tracer:in_flight())
    end).

%% helpers

-spec tracer() -> pid().
tracer() ->
    case whereis(nova_liveboard_tracer) of
        Tracer when is_pid(Tracer) -> Tracer
    end.

%% A request process that is deep-traced the way the plugin does it, has
%% spawned one process and then waits to be told to end, without ever
%% reaching `finalize/2`.
request_process(ReqId, Exit) ->
    Test = self(),
    Tracer = tracer(),
    Before = maps:get(pids, nova_liveboard_tracer:in_flight()),
    Request = spawn(fun() ->
        trace = nova_liveboard_tracer:maybe_arm(ReqId, self()),
        1 = erlang:trace(self(), true, [procs, set_on_spawn, {tracer, Tracer}]),
        Child = spawn(fun() -> ok end),
        Test ! {armed, self(), Child},
        receive
            stop -> exit(Exit)
        end
    end),
    receive
        {armed, Request, _Child} -> ok
    after 1000 -> error(request_not_armed)
    end,
    ok = wait_until(fun() -> maps:get(pids, nova_liveboard_tracer:in_flight()) =:= Before + 2 end),
    Request.

trace_flags(Pid) ->
    case erlang:trace_info(Pid, flags) of
        {flags, Flags} when is_list(Flags) -> lists:sort(Flags)
    end.

request(ReqId) ->
    case nova_liveboard_tracer:get(ReqId) of
        Request when is_map(Request) -> Request
    end.

wait_until(Condition) ->
    wait_until(Condition, 100).

wait_until(_Condition, 0) ->
    timeout;
wait_until(Condition, Attempts) ->
    case Condition() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(Condition, Attempts - 1)
    end.

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
