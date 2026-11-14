-module(nova_liveboard_data_tests).
-include_lib("eunit/include/eunit.hrl").

format_bytes_test_() ->
    [
        ?_assertEqual(~"512 B", nova_liveboard_data:format_bytes(512)),
        ?_assertEqual(~"1.0 KB", nova_liveboard_data:format_bytes(1024)),
        ?_assertEqual(~"1.0 MB", nova_liveboard_data:format_bytes(1048576)),
        ?_assertEqual(~"1.0 GB", nova_liveboard_data:format_bytes(1073741824))
    ].

format_number_test_() ->
    [
        ?_assertEqual(~"42", nova_liveboard_data:format_number(42)),
        ?_assertEqual(~"1.5K", nova_liveboard_data:format_number(1500)),
        ?_assertEqual(~"2.0M", nova_liveboard_data:format_number(2000000))
    ].

format_uptime_test_() ->
    [
        ?_assertEqual(~"00:00:05", nova_liveboard_data:format_uptime(5000)),
        ?_assertEqual(~"00:01:00", nova_liveboard_data:format_uptime(60000)),
        ?_assertEqual(~"1d 00:00:00", nova_liveboard_data:format_uptime(86400000))
    ].

sparkline_points_test_() ->
    [
        ?_assertEqual(~"", nova_liveboard_data:sparkline_points([], 200, 40)),
        %% a single point spans the full width at mid-height
        ?_assertEqual(~"0,20.0 200.0,20.0", nova_liveboard_data:sparkline_points([5], 200, 40)),
        ?_assert(is_binary(nova_liveboard_data:sparkline_points([1, 5, 3, 9, 2], 200, 40))),
        ?_assertEqual(
            ~"0.0,40.0 100.0,20.0 200.0,0.0",
            nova_liveboard_data:sparkline_points([1, 2, 3], 200, 40)
        ),
        ?_assertEqual(
            ~"0.0,40.0 100.0,40.0 200.0,40.0",
            nova_liveboard_data:sparkline_points([3, 3, 3], 200, 40)
        ),
        %% a flat series of floats has a range of 0.0, which is not 0
        ?_assertEqual(
            ~"0.0,40.0 200.0,40.0", nova_liveboard_data:sparkline_points([1.5, 1.5], 200, 40)
        )
    ].

scheduler_info_test() ->
    _ = nova_liveboard_data:collect_metrics(undefined),
    Schedulers = nova_liveboard_data:scheduler_info(),
    ?assert(length(Schedulers) >= erlang:system_info(schedulers)),
    ?assertEqual(
        lists:seq(1, length(Schedulers)), [
            Id
         || #{id := Id, active := Active} <- Schedulers, Active >= 0
        ]
    ).

system_info_shape_test() ->
    Sys = nova_liveboard_data:system_info(),
    ?assert(is_integer(maps:get(process_count, Sys))),
    ?assert(is_integer(maps:get(process_limit, Sys))),
    ?assert(is_map(maps:get(memory, Sys))),
    ?assert(maps:get(process_count, Sys) =< maps:get(process_limit, Sys)).

top_processes_shape_test() ->
    Procs = nova_liveboard_data:top_processes(memory, 5),
    ?assert(length(Procs) =< 5),
    ?assert(lists:all(fun(P) -> is_binary(maps:get(pid, P)) end, Procs)),
    %% sorted descending by the requested key
    Mems = [maps:get(memory, P) || P <- Procs],
    ?assertEqual(lists:reverse(lists:sort(Mems)), Mems).

ets_and_apps_and_ports_shape_test() ->
    ?assert(is_list(nova_liveboard_data:ets_tables())),
    Apps = nova_liveboard_data:running_applications(),
    ?assert(lists:any(fun(A) -> maps:get(name, A) =:= ~"kernel" end, Apps)),
    ?assert(is_list(nova_liveboard_data:port_info())).

supervision_tree_test() ->
    {ok, Tree} = nova_liveboard_data:supervision_tree(kernel),
    ?assert(is_list(Tree)),
    ?assertMatch({error, _}, nova_liveboard_data:supervision_tree(no_such_app_xyz)).

collect_metrics_accumulates_test() ->
    S0 = nova_liveboard_data:collect_metrics(undefined),
    S1 = nova_liveboard_data:collect_metrics(S0),
    ?assertEqual(2, queue:len(maps:get(total_memory, S1))),
    ?assert(is_list(maps:get(scheduler_util, S1))).

%% The application master and the process that starts the application are
%% not supervisors and never answer `which_children`.
unnamed_top_supervisor_test_() ->
    {setup,
        fun() ->
            ok = nova_liveboard_test_unnamed_app:load(),
            ok = application:start(nova_liveboard_test_unnamed)
        end,
        fun(_) ->
            ok = application:stop(nova_liveboard_test_unnamed),
            ok = application:unload(nova_liveboard_test_unnamed)
        end,
        [
            {timeout, 5, fun() ->
                {ok, Tree} = nova_liveboard_data:supervision_tree(nova_liveboard_test_unnamed),
                ?assertEqual(2, length(Tree)),
                ?assertEqual([~"plain"], [Name || #{name := Name} <- Tree, Name =:= ~"plain"]),
                ?assertEqual([worker, worker], [Type || #{type := Type} <- Tree])
            end},
            fun() ->
                [Unnamed] = [
                    App
                 || #{name := ~"nova_liveboard_test_unnamed"} = App <-
                        nova_liveboard_data:running_applications()
                ],
                ?assertEqual(
                    #{
                        name => ~"nova_liveboard_test_unnamed",
                        description => ~"Unnamed \x{2192} top supervisor",
                        version => ~"1.0.0"
                    },
                    Unnamed
                )
            end
        ]}.

kura_schema_test_() ->
    {setup, fun() -> ok = nova_liveboard_test_unnamed_app:load() end,
        fun(_) -> ok = application:unload(nova_liveboard_test_unnamed) end, fun() ->
            ?assertEqual(
                [
                    #{
                        module => ~"nova_liveboard_test_schema",
                        table => ~"things",
                        fields => [
                            #{
                                name => ~"id",
                                type => ~"id",
                                primary_key => true,
                                virtual => false
                            },
                            #{
                                name => ~"name",
                                type => ~"string",
                                primary_key => false,
                                virtual => false
                            },
                            #{
                                name => ~"tags",
                                type => ~"array(string)",
                                primary_key => false,
                                virtual => true
                            }
                        ],
                        associations => [
                            #{
                                name => ~"owner",
                                type => ~"belongs_to",
                                schema => ~"nova_liveboard_test_schema"
                            },
                            #{
                                name => ~"parts",
                                type => ~"has_many",
                                schema => ~"nova_liveboard_test_schema"
                            }
                        ],
                        indexes => [
                            #{columns => [~"name"], unique => true},
                            #{columns => [~"owner_id", ~"name"], unique => false}
                        ]
                    }
                ],
                nova_liveboard_data:kura_schemas(nova_liveboard_test_unnamed_app)
            )
        end}.
