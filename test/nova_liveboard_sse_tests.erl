-module(nova_liveboard_sse_tests).
-include_lib("eunit/include/eunit.hrl").

contains(Hay, Needle) -> binary:match(iolist_to_binary(Hay), Needle) =/= nomatch.

%% The SSE module turns html renders into Datastar patch frames; assert the
%% wire shape it relies on is well-formed.
request_frame_is_valid_sse_test() ->
    R = #{
        id => ~"abc",
        method => ~"GET",
        path => ~"/api/x",
        status => 200,
        duration_us => 500,
        reductions => 1000,
        handler => ~"m:f/1",
        spawned => 2
    },
    Frame = datastar:patch_elements(
        nova_liveboard_html:request_row(R), #{selector => ~"#req-feed", mode => prepend}
    ),
    ?assert(contains(Frame, ~"event: datastar-patch-elements")),
    ?assert(contains(Frame, ~"data: selector #req-feed")),
    ?assert(contains(Frame, ~"data: mode prepend")),
    ?assert(contains(Frame, ~"data: elements")),
    ?assert(contains(Frame, ~"/api/x")).

stream_returns_stream_tuple_test() ->
    Req = #{bindings => #{~"page" => ~"overview"}, qs => ~""},
    {stream, 200, Headers, {Page, Qs}} = nova_liveboard_sse:stream(Req),
    ?assertEqual(~"overview", Page),
    ?assertEqual([], Qs),
    ?assertEqual(~"text/event-stream", maps:get(~"content-type", Headers)).

stream_defaults_page_when_missing_test() ->
    Req = #{bindings => #{}, qs => ~""},
    {stream, 200, _Headers, {Page, _Qs}} = nova_liveboard_sse:stream(Req),
    ?assertEqual(~"overview", Page).

%% ---------------------------------------------------------------------------
%% the poller
%% ---------------------------------------------------------------------------

-define(POLLER, nova_liveboard_poller).
-define(SERVER, nova_liveboard_test_server).
-define(RENDER, {nova_liveboard_page_controller, page_inner, 2}).

poller_test_() ->
    {foreach, fun start_poller/0, fun stop_poller/1, [
        fun one_render_per_view_whatever_the_audience/0,
        fun each_view_is_rendered_separately/0,
        fun vitals_patch_their_own_region/0,
        fun metrics_accumulate_while_watched/0,
        fun requests_repaint_once_per_burst/0,
        fun subscriptions_are_capped/0,
        fun a_slot_is_freed_when_the_subscriber_exits/0,
        fun subscribing_twice_takes_one_slot/0,
        fun nothing_is_rendered_without_subscribers/0,
        fun a_failing_view_does_not_stop_the_others/0,
        fun ticks_follow_the_refresh_interval/0
    ]}.

%% The refresh interval is far away, so a pass only runs when a test sends
%% `tick` itself. Renders are counted with call-count tracing.
start_poller() ->
    application:set_env(nova_liveboard, prefix, ~"/liveboard"),
    application:set_env(nova_liveboard, refresh_ms, 600000),
    application:set_env(nova_liveboard, max_streams, 10),
    {ok, Tracer} = nova_liveboard_tracer:start_link(),
    {ok, Poller} = ?POLLER:start_link(),
    true = unlink(Tracer),
    true = unlink(Poller),
    {module, _} = code:ensure_loaded(nova_liveboard_page_controller),
    1 = erlang:trace_pattern(?RENDER, true, [call_count]),
    {Tracer, Poller}.

stop_poller({Tracer, Poller}) ->
    _ = erlang:trace_pattern(?RENDER, false, [call_count]),
    ok = gen_server:stop(Poller),
    ok = gen_server:stop(Tracer),
    application:set_env(nova_liveboard, prefix, "/liveboard"),
    [application:unset_env(nova_liveboard, Key) || Key <- [refresh_ms, max_streams]],
    ok.

renders() ->
    {call_count, Count} = erlang:trace_info(?RENDER, call_count),
    Count.

one_render_per_view_whatever_the_audience() ->
    Viewers = [viewer({ets, undefined}) || _ <- lists:seq(1, 8)],
    ?POLLER ! tick,
    [Frame | _] = Frames = [frame_from(Viewer) || Viewer <- Viewers],
    ?assertEqual(1, renders()),
    ?assertEqual([Frame], lists:usort(Frames)),
    ?assert(contains(Frame, ~"datastar-patch-elements")),
    ?assert(contains(Frame, ~"selector #page")),
    ?POLLER ! tick,
    _ = [frame_from(Viewer) || Viewer <- Viewers],
    ?assertEqual(2, renders()).

each_view_is_rendered_separately() ->
    Viewers = [
        viewer({processes, memory}),
        viewer({processes, memory}),
        viewer({processes, reductions}),
        viewer({supervisors, kernel}),
        viewer({supervisors, stdlib}),
        viewer({ets, undefined})
    ],
    ?POLLER ! tick,
    Frames = [frame_from(Viewer) || Viewer <- Viewers],
    ?assertEqual(5, renders()),
    ?assertEqual(5, length(lists:usort(Frames))).

vitals_patch_their_own_region() ->
    Viewer = viewer({vitals, undefined}),
    ?POLLER ! tick,
    Frame = frame_from(Viewer),
    ?assert(contains(Frame, ~"selector #vitals")),
    ?assert(contains(Frame, ~"run queue")),
    ?assertEqual(0, renders()).

metrics_accumulate_while_watched() ->
    Viewer = viewer({metrics, undefined}),
    ?POLLER ! tick,
    First = frame_from(Viewer),
    ?POLLER ! tick,
    _ = frame_from(Viewer),
    ?POLLER ! tick,
    Third = frame_from(Viewer),
    ?assert(contains(First, ~"total memory")),
    ?assertEqual({2, 3}, {points(First), points(Third)}),
    exit(Viewer, kill),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end),
    ?POLLER ! tick,
    Again = viewer({metrics, undefined}),
    ?POLLER ! tick,
    ?assertEqual(points(First), points(frame_from(Again))).

points(Frame) ->
    [_, Rest] = binary:split(Frame, ~"points=\""),
    [Points, _] = binary:split(Rest, ~"\""),
    length(binary:split(Points, ~" ", [global])).

requests_repaint_once_per_burst() ->
    application:set_env(nova, plugins, [{pre_request, nova_liveboard_trace_plugin, #{}}]),
    Viewers = [viewer({requests, undefined}) || _ <- lists:seq(1, 4)],
    _ = [frame_from(Viewer) || Viewer <- Viewers],
    ?assertEqual(1, renders()),
    [
        nova_liveboard_tracer:finalize(integer_to_binary(N), #{
            id => integer_to_binary(N),
            method => ~"GET",
            path => <<"/burst/", (integer_to_binary(N))/binary>>,
            handler => ~"m:f/1",
            status => 200,
            duration_us => 1,
            reductions => 1,
            mem => 1,
            ts => 0
        })
     || N <- lists:seq(1, 150)
    ],
    [Frame | _] = Frames = [frame_from(Viewer) || Viewer <- Viewers],
    application:unset_env(nova, plugins),
    ?assertEqual([Frame], lists:usort(Frames)),
    ?assert(contains(Frame, ~"/burst/150")),
    ?assert(contains(Frame, ~"selector #page")),
    timer:sleep(300),
    ?assertEqual(2, renders()),
    ?assertEqual([[], [], [], []], [frames_of(Viewer) || Viewer <- Viewers]),
    ?POLLER ! tick,
    ?assertEqual(4, ?POLLER:stream_count()),
    ?assertEqual(2, renders()).

subscriptions_are_capped() ->
    application:set_env(nova_liveboard, max_streams, 3),
    _ = [viewer({ets, undefined}) || _ <- lists:seq(1, 3)],
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ets, undefined})),
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ports, undefined})),
    ?assertEqual(3, ?POLLER:stream_count()),
    application:set_env(nova_liveboard, max_streams, 0),
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ets, undefined})).

a_slot_is_freed_when_the_subscriber_exits() ->
    application:set_env(nova_liveboard, max_streams, 1),
    Viewer = viewer({ets, undefined}),
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ets, undefined})),
    exit(Viewer, kill),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end),
    ?assertMatch({ok, _}, ?POLLER:subscribe({ets, undefined})).

subscribing_twice_takes_one_slot() ->
    application:set_env(nova_liveboard, max_streams, 1),
    {ok, Poller} = ?POLLER:subscribe({ets, undefined}),
    ?assertEqual({ok, Poller}, ?POLLER:subscribe({ports, undefined})),
    ?assertEqual(Poller, whereis(?POLLER)),
    ?assertEqual(1, ?POLLER:stream_count()).

nothing_is_rendered_without_subscribers() ->
    Viewer = viewer({ets, undefined}),
    exit(Viewer, kill),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end),
    ?POLLER ! tick,
    ?assertEqual(0, ?POLLER:stream_count()),
    ?assertEqual(0, renders()).

a_failing_view_does_not_stop_the_others() ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, critical),
    Broken = viewer({no_such_page, undefined}),
    Working = viewer({ports, undefined}),
    ?POLLER ! tick,
    ?assert(is_binary(frame_from(Working))),
    ?POLLER ! tick,
    ?assert(is_binary(frame_from(Working))),
    ?assertEqual([], frames_of(Broken)),
    ?assert(is_process_alive(whereis(?POLLER))),
    ok = logger:set_primary_config(level, Level).

ticks_follow_the_refresh_interval() ->
    application:set_env(nova_liveboard, refresh_ms, 20),
    Viewer = viewer({ets, undefined}),
    ?assert(is_binary(frame_from(Viewer))),
    ?assert(is_binary(frame_from(Viewer))).

unavailable_without_a_poller_test() ->
    ?assertEqual({error, unavailable}, ?POLLER:subscribe({ets, undefined})).

settings_fall_back_to_their_defaults_test_() ->
    Defaults = [{refresh_ms, 2000}, {max_streams, 50}, {stream_lifetime_ms, 300000}],
    {foreach, fun() -> ok end,
        fun(_) -> [application:unset_env(nova_liveboard, Key) || {Key, _} <- Defaults] end,
        [
            fun() ->
                application:set_env(nova_liveboard, Key, Value),
                ?assertEqual({Key, Value, Default}, {Key, Value, nova_liveboard:Key()})
            end
         || {Key, Default} <- Defaults, Value <- [-1, 1.5, infinity, ~"10", undefined]
        ] ++
            [
                fun() ->
                    application:set_env(nova_liveboard, max_streams, 0),
                    application:set_env(nova_liveboard, refresh_ms, 0),
                    application:set_env(nova_liveboard, stream_lifetime_ms, 0),
                    ?assertEqual(0, nova_liveboard:max_streams()),
                    ?assertEqual(2000, nova_liveboard:refresh_ms()),
                    ?assertEqual(300000, nova_liveboard:stream_lifetime_ms())
                end
            ]}.

%% A process that subscribes and keeps every frame for the test to collect.
viewer(View) ->
    Test = self(),
    Pid = spawn(fun() ->
        Test ! {subscribed, self(), ?POLLER:subscribe(View)},
        collect([])
    end),
    receive
        {subscribed, Pid, {ok, _Poller}} -> Pid
    after 2000 -> error(viewer_did_not_subscribe)
    end.

collect(Frames) ->
    receive
        {nova_liveboard_frame, Frame} ->
            collect([Frame | Frames]);
        {next, From} when Frames =/= [] ->
            From ! {frame, self(), lists:last(Frames)},
            collect(lists:droplast(Frames));
        {all, From} ->
            From ! {frames, self(), lists:reverse(Frames)},
            collect(Frames)
    end.

frame_from(Viewer) ->
    Viewer ! {next, self()},
    receive
        {frame, Viewer, Frame} -> Frame
    after 2000 -> error(no_frame)
    end.

frames_of(Viewer) ->
    Viewer ! {all, self()},
    receive
        {frames, Viewer, Frames} -> Frames
    after 2000 -> error(no_reply)
    end.

%% ---------------------------------------------------------------------------
%% over HTTP
%% ---------------------------------------------------------------------------

stream_test_() ->
    {setup,
        fun() ->
            ?SERVER:start([
                {prefix, ~"/liveboard"},
                {auth, none},
                {refresh_ms, 30},
                {max_streams, 2},
                {stream_lifetime_ms, 400}
            ])
        end,
        fun ?SERVER:stop/1, fun(Server) ->
            [
                {"a stream ends by itself after its lifetime", fun() -> lifetime(Server) end},
                {"streams beyond the limit are refused", fun() -> limit(Server) end},
                {"a closed stream frees its slot", fun() -> disconnect(Server) end},
                {"only live pages have a stream", fun() -> pages(Server) end},
                {"every live page has a stream", fun() -> live_pages(Server) end},
                {"the page asks the browser to reconnect", fun() -> reconnects(Server) end}
            ]
        end}.

lifetime(Server) ->
    Started = erlang:monotonic_time(millisecond),
    Socket = open_stream(Server, ~"/liveboard/sse/ets"),
    {_State, Bytes} = ?SERVER:read(Socket, 1500),
    ok = gen_tcp:close(Socket),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Bytes),
    ?assert(contains(Bytes, ~"datastar-patch-elements")),
    ?assertEqual(~"\r\n0\r\n\r\n", binary:part(Bytes, byte_size(Bytes), -7)),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end),
    ?assert(erlang:monotonic_time(millisecond) - Started >= 400).

limit(Server) ->
    First = open_stream(Server, ~"/liveboard/sse/vitals"),
    Second = open_stream(Server, ~"/liveboard/sse/processes?sort=reductions"),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 2 end),
    Refused = ?SERVER:request(Server, ~"GET /liveboard/sse/ports HTTP/1.1"),
    ?assertEqual(503, ?SERVER:status(Refused)),
    ?assertEqual(~"5", ?SERVER:header(~"retry-after", Refused)),
    ?assertEqual(
        200, ?SERVER:status(?SERVER:request(Server, ~"GET /liveboard/processes HTTP/1.1"))
    ),
    ok = gen_tcp:close(First),
    ok = gen_tcp:close(Second),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end).

disconnect(Server) ->
    Socket = open_stream(Server, ~"/liveboard/sse/requests"),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 1 end),
    ok = gen_tcp:close(Socket),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end),
    Again = open_stream(Server, ~"/liveboard/sse/requests"),
    {open, Bytes} = ?SERVER:read(Again, 300),
    ok = gen_tcp:close(Again),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Bytes),
    ?assert(contains(Bytes, ~"selector #page")),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end).

pages(Server) ->
    [
        ?assertEqual(
            {Page, 404},
            {Page,
                ?SERVER:status(
                    ?SERVER:request(Server, [~"GET /liveboard/sse/", Page, ~" HTTP/1.1"])
                )}
        )
     || Page <- [~"heartbeat", ~"nope", ~"Overview", ~"overview%00", ~"overview/x", ~"%2e%2e"]
    ],
    ?assertEqual(0, ?POLLER:stream_count()).

live_pages(Server) ->
    [
        begin
            Socket = open_stream(Server, [~"/liveboard/sse/", Page]),
            {open, Bytes} = ?SERVER:read(Socket, 300),
            ok = gen_tcp:close(Socket),
            ?assertMatch({Page, <<"HTTP/1.1 200", _/binary>>}, {Page, Bytes}),
            ?assertEqual({Page, true}, {Page, contains(Bytes, <<"selector ", Selector/binary>>)}),
            ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end)
        end
     || {Page, Selector} <- [
            {~"vitals", ~"#vitals"},
            {~"overview", ~"#page"},
            {~"processes", ~"#page"},
            {~"metrics", ~"#page"},
            {~"requests", ~"#page"},
            {~"supervisors?app=kernel", ~"#page"},
            {~"applications", ~"#page"},
            {~"ets", ~"#page"},
            {~"ports", ~"#page"},
            {~"database", ~"#page"},
            {~"schemas", ~"#page"}
        ]
    ].

reconnects(Server) ->
    Body = ?SERVER:body(?SERVER:request(Server, ~"GET /liveboard/ets HTTP/1.1")),
    ?assertEqual(
        2,
        length(
            binary:matches(
                Body,
                ~"data-init=\"@get(el.dataset.liveboardStream, {retry: 'always', retryInterval: 3000})\""
            )
        )
    ).

%% Cowboy closes an HTTP/1.1 connection that receives nothing for its idle
%% timeout. The stream raises it, so the lifetime decides.
idle_timeout_test_() ->
    {setup,
        fun() ->
            ?SERVER:start(
                [
                    {prefix, ~"/liveboard"},
                    {auth, none},
                    {refresh_ms, 600000},
                    {stream_lifetime_ms, 1200}
                ],
                #{idle_timeout => 200}
            )
        end,
        fun ?SERVER:stop/1, fun(Server) ->
            [
                {"a quiet stream outlives the listener's idle timeout", fun() ->
                    Started = erlang:monotonic_time(millisecond),
                    Socket = open_stream(Server, ~"/liveboard/sse/ets"),
                    {closed, Bytes} = ?SERVER:read(Socket, 3000),
                    ok = gen_tcp:close(Socket),
                    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Bytes),
                    ?assertEqual(~"\r\n0\r\n\r\n", binary:part(Bytes, byte_size(Bytes), -7)),
                    ?assert(erlang:monotonic_time(millisecond) - Started >= 1200)
                end}
            ]
        end}.

open_stream(Server, Path) ->
    ?SERVER:open(Server, [~"GET ", Path, ~" HTTP/1.1\r\nhost: board.test\r\n\r\n"]).

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
