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
-define(ME, {peer, {127, 0, 0, 1}}).

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
        fun one_client_cannot_take_every_stream/0,
        fun a_limit_of_zero_refuses_everyone/0,
        fun a_client_gets_its_slot_back/0,
        fun the_limit_over_all_clients_comes_first/0,
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
    [
        application:unset_env(nova_liveboard, Key)
     || Key <- [refresh_ms, max_streams, max_streams_per_client]
    ],
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
    persistent_term:put(nova_plugins, [nova_liveboard_trace_plugin]),
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
    _ = persistent_term:erase(nova_plugins),
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
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ets, undefined}, ?ME)),
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ports, undefined}, ?ME)),
    ?assertEqual(3, ?POLLER:stream_count()),
    application:set_env(nova_liveboard, max_streams, 0),
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ets, undefined}, ?ME)).

a_slot_is_freed_when_the_subscriber_exits() ->
    application:set_env(nova_liveboard, max_streams, 1),
    Viewer = viewer({ets, undefined}),
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ets, undefined}, ?ME)),
    exit(Viewer, kill),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end),
    ?assertMatch({ok, _}, ?POLLER:subscribe({ets, undefined}, ?ME)).

subscribing_twice_takes_one_slot() ->
    application:set_env(nova_liveboard, max_streams, 1),
    application:set_env(nova_liveboard, max_streams_per_client, 1),
    {ok, Poller} = ?POLLER:subscribe({ets, undefined}, ?ME),
    ?assertEqual({ok, Poller}, ?POLLER:subscribe({ports, undefined}, ?ME)),
    ?assertEqual(Poller, whereis(?POLLER)),
    ?assertEqual(1, ?POLLER:stream_count()).

one_client_cannot_take_every_stream() ->
    application:set_env(nova_liveboard, max_streams_per_client, 2),
    Greedy = {identity, ~"greedy"},
    Other = {peer, {192, 0, 2, 7}},
    _ = [viewer({ets, undefined}, Greedy) || _ <- lists:seq(1, 2)],
    [
        ?assertEqual(
            {error, too_many_streams_for_client}, ?POLLER:subscribe({Page, undefined}, Greedy)
        )
     || Page <- [ets, ports, vitals]
    ],
    ?assertEqual(2, ?POLLER:stream_count()),
    _ = [viewer({ets, undefined}, Other) || _ <- lists:seq(1, 2)],
    ?assertEqual({error, too_many_streams_for_client}, ?POLLER:subscribe({ets, undefined}, Other)),
    ?assertMatch({ok, _}, ?POLLER:subscribe({ets, undefined}, {peer, {192, 0, 2, 8}})),
    ?assertMatch({ok, _}, ?POLLER:subscribe({ports, undefined}, {peer, {192, 0, 2, 8}})),
    ?assertEqual(5, ?POLLER:stream_count()),
    %% Subscribing again does not move this process to another client.
    ?assertMatch({ok, _}, ?POLLER:subscribe({ets, undefined}, Greedy)),
    ?assertEqual(5, ?POLLER:stream_count()),
    _ = viewer({ets, undefined}, {peer, {192, 0, 2, 8}}),
    ?assertEqual(
        {error, too_many_streams_for_client},
        subscribe_once({ets, undefined}, {peer, {192, 0, 2, 8}})
    ),
    ?assertEqual(6, ?POLLER:stream_count()).

a_limit_of_zero_refuses_everyone() ->
    application:set_env(nova_liveboard, max_streams_per_client, 0),
    ?assertEqual({error, too_many_streams_for_client}, ?POLLER:subscribe({ets, undefined}, ?ME)),
    ?assertEqual(0, ?POLLER:stream_count()).

a_client_gets_its_slot_back() ->
    application:set_env(nova_liveboard, max_streams_per_client, 1),
    Client = {identity, ~"operator"},
    Viewer = viewer({ets, undefined}, Client),
    ?assertEqual({error, too_many_streams_for_client}, ?POLLER:subscribe({ets, undefined}, Client)),
    exit(Viewer, kill),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end),
    ?assertMatch({ok, _}, ?POLLER:subscribe({ets, undefined}, Client)).

the_limit_over_all_clients_comes_first() ->
    application:set_env(nova_liveboard, max_streams, 2),
    application:set_env(nova_liveboard, max_streams_per_client, 2),
    Client = {identity, ~"operator"},
    _ = [viewer({ets, undefined}, Client) || _ <- lists:seq(1, 2)],
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ets, undefined}, Client)),
    ?assertEqual({error, too_many_streams}, ?POLLER:subscribe({ets, undefined}, ?ME)).

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
    ?assertEqual({error, unavailable}, ?POLLER:subscribe({ets, undefined}, ?ME)).

settings_fall_back_to_their_defaults_test_() ->
    Defaults = [
        {refresh_ms, 2000},
        {max_streams, 50},
        {max_streams_per_client, 6},
        {stream_lifetime_ms, 300000}
    ],
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
                    application:set_env(nova_liveboard, max_streams_per_client, 0),
                    application:set_env(nova_liveboard, refresh_ms, 0),
                    application:set_env(nova_liveboard, stream_lifetime_ms, 0),
                    ?assertEqual(0, nova_liveboard:max_streams()),
                    ?assertEqual(0, nova_liveboard:max_streams_per_client()),
                    ?assertEqual(2000, nova_liveboard:refresh_ms()),
                    ?assertEqual(300000, nova_liveboard:stream_lifetime_ms())
                end
            ]}.

%% A process that subscribes and keeps every frame for the test to collect.
%% Without a client it is one of its own, as a viewer nobody else shares an
%% identity or an address with.
viewer(View) ->
    viewer(View, {identity, integer_to_binary(erlang:unique_integer([positive]))}).

viewer(View, Client) ->
    Test = self(),
    Pid = spawn(fun() ->
        Test ! {subscribed, self(), ?POLLER:subscribe(View, Client)},
        collect([])
    end),
    receive
        {subscribed, Pid, {ok, _Poller}} -> Pid
    after 2000 -> error(viewer_did_not_subscribe)
    end.

%% What a process that subscribes, and then exits, is answered.
subscribe_once(View, Client) ->
    Test = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Test ! {answer, self(), ?POLLER:subscribe(View, Client)}
    end),
    receive
        {answer, Pid, Answer} ->
            receive
                {'DOWN', Monitor, process, Pid, _Reason} -> Answer
            after 2000 -> error(subscriber_did_not_exit)
            end
    after 2000 -> error(no_answer)
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
%% who a stream belongs to
%% ---------------------------------------------------------------------------

client_is_the_identity_from_auth_test() ->
    Peer = {{192, 0, 2, 1}, 50000},
    Operator = #{user => ~"operator", session => ~"correct horse battery staple"},
    {identity, Digest} = Client = nova_liveboard_sse:client(#{auth_data => Operator, peer => Peer}),
    ?assertEqual(
        Client,
        nova_liveboard_sse:client(#{auth_data => Operator, peer => {{198, 51, 100, 9}, 1234}})
    ),
    ?assertNotEqual(
        Client, nova_liveboard_sse:client(#{auth_data => Operator#{user => ~"other"}, peer => Peer})
    ),
    ?assertEqual(32, byte_size(Digest)),
    ?assertEqual(nomatch, binary:match(term_to_binary(Client), ~"horse")).

client_is_the_address_without_an_identity_test_() ->
    [
        ?_assertEqual({peer, Address}, nova_liveboard_sse:client(#{peer => {Seen, Port}}))
     || {Seen, Port, Address} <- [
            {{192, 0, 2, 1}, 50000, {192, 0, 2, 1}},
            {{192, 0, 2, 1}, 50001, {192, 0, 2, 1}},
            {{192, 0, 2, 2}, 50000, {192, 0, 2, 2}},
            {{8193, 3512, 1, 2, 3, 4, 5, 6}, 50000, {8193, 3512, 1, 2, 0, 0, 0, 0}},
            {{8193, 3512, 1, 2, 9, 9, 9, 9}, 50000, {8193, 3512, 1, 2, 0, 0, 0, 0}},
            {{8193, 3512, 1, 3, 3, 4, 5, 6}, 50000, {8193, 3512, 1, 3, 0, 0, 0, 0}}
        ]
    ].

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

per_client_test_() ->
    {setup,
        fun() ->
            ?SERVER:start([
                {prefix, ~"/liveboard"},
                {auth, {nova_liveboard_test_auth, identified}},
                {refresh_ms, 30},
                {max_streams, 10},
                {max_streams_per_client, 2}
            ])
        end,
        fun ?SERVER:stop/1, fun(Server) ->
            [
                {"one viewer cannot take every stream", fun() -> quota(Server) end},
                {"without an identity the address is the viewer", fun() -> by_address(Server) end}
            ]
        end}.

quota(Server) ->
    Mine = [open_stream(Server, ~"/liveboard/sse/ets", ~"alice") || _ <- lists:seq(1, 2)],
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 2 end),
    Refused = ?SERVER:request(Server, ~"GET /liveboard/sse/ports HTTP/1.1", user(~"alice")),
    ?assertEqual(429, ?SERVER:status(Refused)),
    ?assertEqual(~"5", ?SERVER:header(~"retry-after", Refused)),
    ?assertEqual(
        200,
        ?SERVER:status(?SERVER:request(Server, ~"GET /liveboard/ports HTTP/1.1", user(~"alice")))
    ),
    Theirs = open_stream(Server, ~"/liveboard/sse/ports", ~"bob"),
    {open, Bytes} = ?SERVER:read(Theirs, 300),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Bytes),
    ?assertEqual(3, ?POLLER:stream_count()),
    [ok = gen_tcp:close(Socket) || Socket <- [Theirs | Mine]],
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end),
    Again = open_stream(Server, ~"/liveboard/sse/ports", ~"alice"),
    ?assertMatch({open, <<"HTTP/1.1 200", _/binary>>}, ?SERVER:read(Again, 300)),
    ok = gen_tcp:close(Again),
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end).

by_address(Server) ->
    Open = [open_stream(Server, ~"/liveboard/sse/ets") || _ <- lists:seq(1, 2)],
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 2 end),
    ?assertEqual(
        429, ?SERVER:status(?SERVER:request(Server, ~"GET /liveboard/sse/ports HTTP/1.1"))
    ),
    Named = open_stream(Server, ~"/liveboard/sse/ports", ~"carol"),
    ?assertMatch({open, <<"HTTP/1.1 200", _/binary>>}, ?SERVER:read(Named, 300)),
    [ok = gen_tcp:close(Socket) || Socket <- [Named | Open]],
    ok = wait_until(fun() -> ?POLLER:stream_count() =:= 0 end).

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

open_stream(Server, Path, User) ->
    ?SERVER:open(Server, [
        ~"GET ", Path, ~" HTTP/1.1\r\nhost: board.test\r\nx-test-user: ", User, ~"\r\n\r\n"
    ]).

user(Name) ->
    [{~"x-test-user", Name}].

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
