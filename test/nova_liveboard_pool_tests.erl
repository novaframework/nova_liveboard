-module(nova_liveboard_pool_tests).
-include_lib("eunit/include/eunit.hrl").

-define(KURA, nova_liveboard_test_kura).
-define(FIGURES, #{
    size => 10,
    in_use => 2,
    idle => 3,
    waiting => 1,
    counters => [
        {~"checkouts", 120},
        {~"waits", 7},
        {~"timeouts", 1},
        {~"disconnects", 4},
        {~"retired", 2}
    ]
}).

pool_test_() ->
    {foreach,
        fun() ->
            ?KURA:start(#{
                shop_repo => ?KURA:postgres(shop_pool),
                files_repo => ?KURA:sqlite(),
                other_repo => #{pool_module => some_pool_module, password => "hunter2"}
            })
        end,
        fun(_) -> ?KURA:stop() end, [
            fun minato_pool_figures/0,
            fun minato_pool_not_started/0,
            fun minato_absent/0,
            fun minato_without_stats/0,
            fun minato_pool_that_does_not_answer/0,
            fun minato_answer_in_an_unknown_shape/0,
            fun minato_answer_without_a_counter/0,
            fun sqlite_pool_has_no_figures/0,
            fun pool_module_without_an_adapter/0,
            fun repo_without_a_pool_module/0,
            fun pool_kura_did_not_start/0,
            fun pool_owned_by_another_repo/0,
            fun kura_reason_is_not_repeated/0,
            fun kura_db_absent/0,
            fun kura_db_without_get_pool_module/0,
            fun pools_share_one_deadline/0
        ]}.

minato_pool_figures() ->
    ok = ?KURA:minato(),
    Pool = ?KURA:pool(shop_pool, ?KURA:stats()),
    try
        ?assertEqual(
            #{
                status => ~"running",
                backend => ~"postgres (minato)",
                name => ~"shop_pool",
                figures => ?FIGURES
            },
            read(shop_repo)
        )
    after
        ok = gen_server:stop(Pool)
    end.

minato_pool_not_started() ->
    ok = ?KURA:minato(),
    ?assertEqual(
        #{
            status => ~"not started",
            backend => ~"postgres (minato)",
            name => ~"shop_pool",
            reason => ~"no pool is running under this name"
        },
        read(shop_repo)
    ).

minato_absent() ->
    Pool = ?KURA:pool(shop_pool, ?KURA:stats()),
    try
        ?assertEqual(
            #{
                status => ~"not available",
                backend => ~"postgres (minato)",
                name => ~"shop_pool",
                reason => ~"minato is not on this node"
            },
            read(shop_repo)
        )
    after
        ok = gen_server:stop(Pool)
    end.

minato_without_stats() ->
    ok = ?KURA:minato_without_stats(),
    Pool = ?KURA:pool(shop_pool, ?KURA:stats()),
    try
        ?assertEqual(
            #{
                status => ~"not available",
                backend => ~"postgres (minato)",
                name => ~"shop_pool",
                reason => ~"minato:stats/1 is not exported by the minato on this node"
            },
            read(shop_repo)
        )
    after
        ok = gen_server:stop(Pool)
    end.

minato_pool_that_does_not_answer() ->
    ok = ?KURA:minato(),
    Pool = ?KURA:pool(shop_pool, blocked),
    try
        Started = erlang:monotonic_time(millisecond),
        ?assertEqual(
            #{
                status => ~"no answer",
                backend => ~"postgres (minato)",
                name => ~"shop_pool",
                reason => ~"the pool did not answer in time"
            },
            read(shop_repo)
        ),
        Waited = erlang:monotonic_time(millisecond) - Started,
        ?assert(Waited >= 1000),
        ?assert(Waited < 2500)
    after
        ok = gen_server:stop(Pool)
    end.

minato_answer_in_an_unknown_shape() ->
    ok = ?KURA:minato(),
    Pool = ?KURA:pool(shop_pool, #{size => 10, idle => many}),
    try
        ?assertMatch(
            #{
                status := ~"not available",
                reason := ~"minato:stats/1 answered in a shape the liveboard does not know"
            },
            read(shop_repo)
        )
    after
        ok = gen_server:stop(Pool)
    end.

minato_answer_without_a_counter() ->
    ok = ?KURA:minato(),
    Pool = ?KURA:pool(shop_pool, maps:without([retired, waits], ?KURA:stats())),
    try
        ?assertMatch(
            #{
                status := ~"running",
                figures := #{
                    size := 10,
                    counters := [{~"checkouts", 120}, {~"timeouts", 1}, {~"disconnects", 4}]
                }
            },
            read(shop_repo)
        )
    after
        ok = gen_server:stop(Pool)
    end.

sqlite_pool_has_no_figures() ->
    ?assertEqual(
        #{
            status => ~"not available",
            backend => ~"sqlite",
            name => ~"files_repo",
            reason => ~"kura_pool_sqlite exports no function that reports pool figures"
        },
        read(files_repo)
    ).

pool_module_without_an_adapter() ->
    ?assertEqual(
        #{
            status => ~"not available",
            backend => ~"some_pool_module",
            name => ~"other_repo",
            reason => ~"the liveboard has no adapter for this pool module"
        },
        read(other_repo)
    ).

repo_without_a_pool_module() ->
    ?assertEqual(
        #{status => ~"not available", reason => ~"the repo has no pool module configured"},
        read(nova_liveboard_test_repo)
    ).

pool_kura_did_not_start() ->
    ok = ?KURA:kept(shop_repo, {pool_not_started, shop_pool}),
    ?assertEqual(
        #{status => ~"not started", reason => ~"kura did not start the pool shop_pool"},
        read(shop_repo)
    ).

pool_owned_by_another_repo() ->
    ok = ?KURA:kept(shop_repo, {pool_owned_by, files_repo}),
    ?assertEqual(
        #{status => ~"not started", reason => ~"the pool belongs to the repo files_repo"},
        read(shop_repo)
    ).

kura_reason_is_not_repeated() ->
    ok = application:set_env(kura, repos, #{
        nova_liveboard_test_raising_repo => ?KURA:postgres(shop_pool)
    }),
    ?assertError(
        {badmatch, #{password := "hunter2"}}, kura_db:get_pool(nova_liveboard_test_raising_repo)
    ),
    ?assertEqual(
        #{
            status => ~"not available",
            reason => ~"kura could not say which pool the repo uses"
        },
        read(nova_liveboard_test_raising_repo)
    ).

kura_db_absent() ->
    ok = nova_liveboard_test_library:remove(kura_db),
    ?assertEqual(
        #{status => ~"not available", reason => ~"kura_db is not on this node"},
        read(shop_repo)
    ).

kura_db_without_get_pool_module() ->
    ok = nova_liveboard_test_library:remove(kura_db),
    ok = nova_liveboard_test_library:install(
        kura_db, nova_liveboard_fake_kura_db, [{get_pool_module, 1}]
    ),
    ?assertEqual(
        #{
            status => ~"not available",
            reason => ~"kura_db:get_pool_module/1 is not exported by the kura on this node"
        },
        read(shop_repo)
    ).

pools_share_one_deadline() ->
    ok = application:set_env(kura, repos, #{
        shop_repo => ?KURA:postgres(shop_pool),
        files_repo => ?KURA:postgres(files_pool),
        other_repo => ?KURA:postgres(other_pool)
    }),
    ok = ?KURA:minato(),
    Blocked = [?KURA:pool(Name, blocked) || Name <- [shop_pool, files_pool]],
    Answering = ?KURA:pool(other_pool, ?KURA:stats()),
    try
        Started = erlang:monotonic_time(millisecond),
        Asked = [nova_liveboard_pool:ask(Repo) || Repo <- [shop_repo, files_repo, other_repo]],
        Deadline = nova_liveboard_pool:deadline(),
        ?assertMatch(
            [
                #{status := ~"no answer", name := ~"shop_pool"},
                #{status := ~"no answer", name := ~"files_pool"},
                #{status := ~"running", name := ~"other_pool"}
            ],
            [nova_liveboard_pool:answer(Pool, Deadline) || Pool <- Asked]
        ),
        ?assert(erlang:monotonic_time(millisecond) - Started < 2000)
    after
        _ = [gen_server:stop(Pool) || Pool <- [Answering | Blocked]]
    end.

read(Repo) ->
    nova_liveboard_pool:answer(nova_liveboard_pool:ask(Repo), nova_liveboard_pool:deadline()).
