-module(nova_liveboard_redact_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, nova_liveboard_redact).
-define(HEX, ~"9f86d081884c7d659a2feaa0c55ad015").
-define(UUID, ~"0190f3c2-7a1e-7c4b-9d0e-5b6a7c8d9e0f").
-define(JWT, ~"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl").

redact_test_() ->
    {foreach, fun() -> ok end, fun(_) -> application:unset_env(nova_liveboard, redact) end, [
        fun standard_masks_token_like_segments/0,
        fun standard_keeps_ordinary_paths/0,
        fun standard_cuts_a_port_name_after_the_program/0,
        fun standard_prints_child_ids_bounded/0,
        fun none_shows_everything_bounded/0,
        fun all_hides_everything/0,
        fun callback_decides/0,
        fun failing_callback_hides_the_value/0,
        fun unknown_setting_is_all/0
    ]}.

standard_masks_token_like_segments() ->
    ?assertEqual(standard, nova_liveboard:redact()),
    [
        ?assertEqual(Shown, ?M:request_path(Path))
     || {Path, Shown} <- [
            {<<"/reset/", ?HEX/binary>>, ~"/reset/[redacted]"},
            {<<"/reset/", ?HEX/binary, "/confirm">>, ~"/reset/[redacted]/confirm"},
            {<<"/api/keys/", ?UUID/binary>>, ~"/api/keys/[redacted]"},
            {<<"/auth/", ?JWT/binary>>, ~"/auth/[redacted]"},
            {<<"/", ?HEX/binary, "/", ?HEX/binary>>, ~"/[redacted]/[redacted]"},
            {<<"/dl/abcdefghij0123456789">>, ~"/dl/[redacted]"}
        ]
    ].

standard_keeps_ordinary_paths() ->
    [
        ?assertEqual(Path, ?M:request_path(Path))
     || Path <- [
            ~"/",
            ~"",
            ~"/api/widgets",
            ~"/api/widgets/42",
            ~"/users/1234567890123456789",
            ~"/blog/a-long-title-without-any-number-in-it",
            ~"/assets/app.3f9a1c.js",
            ~"//double//slash/"
        ]
    ].

standard_cuts_a_port_name_after_the_program() ->
    ?assertEqual(~"tcp_inet", ?M:port_name(~"tcp_inet")),
    ?assertEqual(~"/usr/bin/psql", ?M:port_name(~"/usr/bin/psql")),
    ?assertEqual(
        ~"psql [redacted]", ?M:port_name(~"psql postgres://app:hunter2@db.internal/prod")
    ),
    ?assertEqual(~"sh [redacted]", ?M:port_name(~"sh\t-c PGPASSWORD=hunter2 pg_dump")),
    ?assertEqual(~"", ?M:port_name(~"")).

standard_prints_child_ids_bounded() ->
    ?assertEqual(~"{pool,<<\"main\">>}", ?M:child_id({pool, ~"main"})),
    ?assert(byte_size(?M:child_id({pool, lists:duplicate(5000, $a)})) =< 250).

none_shows_everything_bounded() ->
    application:set_env(nova_liveboard, redact, none),
    Path = <<"/reset/", ?HEX/binary>>,
    ?assertEqual(Path, ?M:request_path(Path)),
    ?assertEqual(~"psql -h db", ?M:port_name(~"psql -h db")),
    Long = binary:copy(~"a", 9000),
    ?assertEqual(515, byte_size(?M:request_path(Long))),
    ?assertEqual(515, byte_size(?M:port_name(Long))).

all_hides_everything() ->
    application:set_env(nova_liveboard, redact, all),
    ?assertEqual(~"[redacted]", ?M:request_path(~"/api/widgets")),
    ?assertEqual(~"[redacted]", ?M:port_name(~"tcp_inet")),
    ?assertEqual(~"[redacted]", ?M:child_id({pool, main})).

callback_decides() ->
    application:set_env(nova_liveboard, redact, {nova_liveboard_test_redact, shown}),
    ?assertEqual(~"/files/:name", ?M:request_path(~"/files/report.pdf")),
    ?assertEqual(<<"/reset/", ?HEX/binary>>, ?M:request_path(<<"/reset/", ?HEX/binary>>)),
    ?assertEqual(~"a port", ?M:port_name(~"psql -h db")),
    ?assertEqual(~"child {pool,main}", ?M:child_id({pool, main})).

failing_callback_hides_the_value() ->
    [
        begin
            application:set_env(nova_liveboard, redact, Callback),
            ?assertEqual(~"[redacted]", ?M:request_path(~"/api/widgets")),
            ?assertEqual(~"[redacted]", ?M:port_name(~"tcp_inet")),
            ?assertEqual(~"[redacted]", ?M:child_id({pool, main}))
        end
     || Callback <- [
            {nova_liveboard_test_redact, broken},
            {nova_liveboard_test_redact, no_such_function},
            {nova_liveboard_no_such_module, shown}
        ]
    ].

unknown_setting_is_all() ->
    [
        begin
            application:set_env(nova_liveboard, redact, Value),
            ?assertEqual({Value, all}, {Value, nova_liveboard:redact()}),
            ?assertEqual(~"[redacted]", ?M:request_path(~"/api/widgets"))
        end
     || Value <- [true, false, undefined, [], ~"none", "standard", {a, b, c}, 1]
    ].

%% ---------------------------------------------------------------------------
%% where it is applied
%% ---------------------------------------------------------------------------

capture_test_() ->
    {foreach,
        fun() ->
            {ok, Tracer} = nova_liveboard_tracer:start_link(),
            Tracer
        end,
        fun(Tracer) ->
            gen_server:stop(Tracer),
            application:unset_env(nova_liveboard, redact)
        end,
        [
            fun the_tracer_never_holds_the_original_path/0,
            fun the_query_string_is_never_captured/0,
            fun a_hidden_path_is_still_listed/0
        ]}.

the_tracer_never_holds_the_original_path() ->
    captured(#{method => ~"GET", path => <<"/reset/", ?HEX/binary>>, qs => ~""}),
    [Request] = nova_liveboard_tracer:recent(),
    ?assertEqual(~"/reset/[redacted]", maps:get(path, Request)),
    State = iolist_to_binary(io_lib:format("~p", [sys:get_state(nova_liveboard_tracer)])),
    ?assertEqual(nomatch, binary:match(State, ?HEX)),
    Row = iolist_to_binary(nova_liveboard_html:request_row(Request)),
    Detail = iolist_to_binary(nova_liveboard_html:request_detail_html(Request)),
    [?assertEqual(nomatch, binary:match(Html, ?HEX)) || Html <- [Row, Detail]],
    ?assertNotEqual(nomatch, binary:match(Row, ~"/reset/[redacted]")).

the_query_string_is_never_captured() ->
    application:set_env(nova_liveboard, redact, none),
    captured(#{method => ~"GET", path => ~"/search", qs => <<"token=", ?HEX/binary>>}),
    State = iolist_to_binary(io_lib:format("~p", [sys:get_state(nova_liveboard_tracer)])),
    ?assertEqual(nomatch, binary:match(State, ?HEX)),
    ?assertNotEqual(nomatch, binary:match(State, ~"/search")).

a_hidden_path_is_still_listed() ->
    application:set_env(nova_liveboard, redact, all),
    captured(#{method => ~"POST", path => ~"/api/widgets", qs => ~""}),
    [Request] = nova_liveboard_tracer:recent(),
    ?assertEqual(~"[redacted]", maps:get(path, Request)),
    ?assertEqual(~"POST", maps:get(method, Request)),
    ?assertEqual(201, maps:get(status, Request)).

captured(Req0) ->
    Env = #{callback => fun lists:reverse/1},
    {ok, Req, State} = nova_liveboard_trace_plugin:pre_request(Req0, Env, #{}, undefined),
    {ok, _, _} = nova_liveboard_trace_plugin:post_request(
        Req#{resp_status_code => 201}, Env, #{}, State
    ).

ports_test_() ->
    {setup,
        fun() ->
            Secret = "hunter2-" ++ integer_to_list(erlang:unique_integer([positive])),
            Port = open_port({spawn, "sleep 30 # " ++ Secret}, []),
            {Port, list_to_binary(Secret)}
        end,
        fun({Port, _Secret}) ->
            catch port_close(Port),
            application:unset_env(nova_liveboard, redact)
        end,
        fun({_Port, Secret}) ->
            [
                {"a command line is cut after the program", fun() ->
                    Names = [maps:get(name, Info) || Info <- nova_liveboard_data:port_info()],
                    ?assert(lists:member(~"sleep [redacted]", Names)),
                    ?assertEqual([], [Name || Name <- Names, has(Name, Secret)]),
                    Html = iolist_to_binary(
                        nova_liveboard_html:ports_html(nova_liveboard_data:port_info())
                    ),
                    ?assertNot(has(Html, Secret))
                end},
                {"none shows the command line", fun() ->
                    application:set_env(nova_liveboard, redact, none),
                    Names = [maps:get(name, Info) || Info <- nova_liveboard_data:port_info()],
                    ?assertEqual(1, length([Name || Name <- Names, has(Name, Secret)]))
                end}
            ]
        end}.

child_ids_test_() ->
    {setup,
        fun() ->
            {ok, Sup} = supervisor:start_link(
                {local, nova_liveboard_redact_fixture_sup}, nova_liveboard_test_redact, []
            ),
            true = unlink(Sup),
            Sup
        end,
        fun(Sup) ->
            application:unset_env(nova_liveboard, redact),
            Monitor = erlang:monitor(process, Sup),
            exit(Sup, shutdown),
            receive
                {'DOWN', Monitor, process, Sup, _Reason} -> ok
            after 5000 -> error(fixture_supervisor_did_not_stop)
            end
        end,
        fun(_Sup) ->
            [
                {"a term child id is hidden under all", fun() ->
                    application:set_env(nova_liveboard, redact, all),
                    ?assertEqual(
                        [~"[redacted]", ~"plain"],
                        lists:sort([maps:get(name, Child) || Child <- tree()])
                    )
                end},
                {"and printed otherwise", fun() ->
                    application:unset_env(nova_liveboard, redact),
                    ?assertEqual(
                        [~"plain", ~"{pool,\"postgres://app:hunter2@db/prod\"}"],
                        lists:sort([maps:get(name, Child) || Child <- tree()])
                    )
                end}
            ]
        end}.

tree() ->
    {ok, Tree} = nova_liveboard_data:supervision_tree(nova_liveboard_redact_fixture),
    Tree.

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.
