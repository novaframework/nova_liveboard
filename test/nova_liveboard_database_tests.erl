-module(nova_liveboard_database_tests).
-include_lib("eunit/include/eunit.hrl").

-define(KURA, nova_liveboard_test_kura).

database_page_test_() ->
    {foreach, fun() -> ?KURA:start(#{nova_liveboard_test_repo => ?KURA:postgres(shop_pool)}) end,
        fun(_) -> ?KURA:stop() end, [
            fun page_shows_the_figures_of_a_minato_pool/0,
            fun page_says_why_there_are_no_figures/0,
            fun page_does_not_wait_for_a_pool_that_does_not_answer/0,
            fun page_without_kura/0
        ]}.

page_shows_the_figures_of_a_minato_pool() ->
    ok = ?KURA:minato(),
    Pool = ?KURA:pool(shop_pool, ?KURA:stats()),
    try
        Page = page(),
        [
            ?assertNotEqual(nomatch, binary:match(Page, Shown))
         || Shown <- [
                ~">nova_liveboard_test_repo</h3>",
                row(~"database", ~"shop"),
                row(~"host", ~"db.internal"),
                row(~"port", ~"5432"),
                row(~"backend", ~"postgres (minato)"),
                ~"shop_pool <span class=\"status s2\">running</span>",
                row(~"pool size", ~"10"),
                row(~"in use", ~"2"),
                row(~"idle", ~"3"),
                row(~"waiting", ~"1"),
                row(~"checkouts", ~"120"),
                row(~"waits", ~"7"),
                row(~"timeouts", ~"1"),
                row(~"disconnects", ~"4"),
                row(~"retired", ~"2")
            ]
        ]
    after
        ok = gen_server:stop(Pool)
    end.

page_says_why_there_are_no_figures() ->
    Page = page(),
    ?assertNotEqual(
        nomatch, binary:match(Page, ~"shop_pool <span class=\"status idle\">not available</span>")
    ),
    ?assertNotEqual(
        nomatch, binary:match(Page, row(~"pool figures", ~"minato is not on this node"))
    ),
    ?assertNotEqual(nomatch, binary:match(Page, row(~"configured size", ~"10"))),
    ?assertEqual(nomatch, binary:match(Page, ~">in use<")).

page_does_not_wait_for_a_pool_that_does_not_answer() ->
    ok = ?KURA:minato(),
    Pool = ?KURA:pool(shop_pool, blocked),
    try
        Started = erlang:monotonic_time(millisecond),
        Page = page(),
        ?assert(erlang:monotonic_time(millisecond) - Started < 2500),
        ?assertNotEqual(
            nomatch, binary:match(Page, ~"shop_pool <span class=\"status s4\">no answer</span>")
        ),
        ?assertNotEqual(
            nomatch, binary:match(Page, row(~"pool figures", ~"the pool did not answer in time"))
        )
    after
        ok = gen_server:stop(Pool)
    end.

page_without_kura() ->
    ok = ?KURA:stop(),
    ?assertNotEqual(nomatch, binary:match(page(), ~"no kura repos detected")).

%% ---------------------------------------------------------------------------
%% nothing of the connection configuration but what is shown
%% ---------------------------------------------------------------------------

-define(SECRET, "s3cr3t-canary-7f3a").
-define(IN_URL, "url-canary-91c4").

secrets_test_() ->
    {foreach,
        fun() ->
            ?KURA:start(#{
                nova_liveboard_test_repo => with_secrets(),
                nova_liveboard_test_raising_repo => with_secrets()
            })
        end,
        fun(_) ->
            application:unset_env(nova_liveboard, redact),
            ?KURA:stop()
        end,
        [
            fun no_secret_with_a_pool_that_answers/0,
            fun no_secret_without_minato/0,
            fun no_secret_with_a_pool_that_is_not_started/0,
            fun no_secret_with_a_pool_that_does_not_answer/0,
            fun no_secret_when_kura_fails_with_the_configuration/0,
            fun no_secret_under_all/0,
            fun no_secret_when_the_redact_callback_fails/0,
            fun none_still_masks_credentials_in_the_name_and_host/0
        ]}.

with_secrets() ->
    Config = ?KURA:postgres(shop_pool),
    Config#{
        database =>
            "postgres://" ++ ?IN_URL ++ ":" ++ ?IN_URL ++ "@db.internal/shop?sslpassword=" ++
            ?IN_URL,
        host => ?IN_URL ++ ":" ++ ?IN_URL ++ "@db.internal",
        user => ?SECRET,
        username => ?SECRET,
        password => ?SECRET,
        url => "postgres://" ++ ?SECRET ++ ":" ++ ?SECRET ++ "@db.internal/shop",
        ssl_options => [{password, ?SECRET}, {key, {'RSAPrivateKey', list_to_binary(?SECRET)}}],
        encryption => #{key => list_to_binary(?SECRET)},
        socket_options => [{?SECRET, ?SECRET}]
    }.

no_secret_with_a_pool_that_answers() ->
    ok = ?KURA:minato(),
    Pool = ?KURA:pool(shop_pool, ?KURA:stats()),
    try
        Page = without_secrets(),
        ?assertNotEqual(
            nomatch,
            binary:match(
                Page, row(~"database", ~"postgres://[redacted]@db.internal/shop?[redacted]")
            )
        ),
        ?assertNotEqual(nomatch, binary:match(Page, row(~"host", ~"[redacted]@db.internal"))),
        ?assertNotEqual(nomatch, binary:match(Page, row(~"in use", ~"2")))
    after
        ok = gen_server:stop(Pool)
    end.

no_secret_without_minato() ->
    Page = without_secrets(),
    ?assertNotEqual(
        nomatch, binary:match(Page, row(~"pool figures", ~"minato is not on this node"))
    ).

no_secret_with_a_pool_that_is_not_started() ->
    ok = ?KURA:minato(),
    Page = without_secrets(),
    ?assertNotEqual(
        nomatch, binary:match(Page, row(~"pool figures", ~"no pool is running under this name"))
    ).

no_secret_with_a_pool_that_does_not_answer() ->
    ok = ?KURA:minato(),
    Pool = ?KURA:pool(shop_pool, blocked),
    try
        Page = without_secrets(),
        ?assertNotEqual(
            nomatch, binary:match(Page, row(~"pool figures", ~"the pool did not answer in time"))
        )
    after
        ok = gen_server:stop(Pool)
    end.

no_secret_when_kura_fails_with_the_configuration() ->
    Repo = nova_liveboard_test_raising_repo,
    ?assertError({badmatch, #{password := ?SECRET}}, kura_repo:config(Repo)),
    Logged = nova_liveboard_test_log:logged(fun() ->
        Infos = nova_liveboard_data:kura_repo_infos([Repo]),
        Page = iolist_to_binary(nova_liveboard_html:database_html(Infos)),
        [
            ?assertEqual(nomatch, binary:match(Shown, Secret))
         || Shown <- [Page, printed(Infos)], Secret <- secrets()
        ],
        ?assertNotEqual(
            nomatch,
            binary:match(
                Page, row(~"pool figures", ~"kura could not say which pool the repo uses")
            )
        )
    end),
    [?assertEqual(nomatch, binary:match(Logged, Secret)) || Secret <- secrets()].

no_secret_under_all() ->
    application:set_env(nova_liveboard, redact, all),
    Page = without_secrets(),
    ?assertNotEqual(nomatch, binary:match(Page, row(~"database", ~"[redacted]"))),
    ?assertNotEqual(nomatch, binary:match(Page, row(~"host", ~"[redacted]"))).

no_secret_when_the_redact_callback_fails() ->
    application:set_env(nova_liveboard, redact, {nova_liveboard_test_redact, broken}),
    Page = without_secrets(),
    ?assertNotEqual(nomatch, binary:match(Page, row(~"database", ~"[redacted]"))),
    ?assertNotEqual(nomatch, binary:match(Page, row(~"host", ~"[redacted]"))).

none_still_masks_credentials_in_the_name_and_host() ->
    application:set_env(nova_liveboard, redact, none),
    Page = without_secrets(),
    ?assertNotEqual(nomatch, binary:match(Page, row(~"host", ~"[redacted]@db.internal"))).

%% The page, once neither it, nor what it was rendered from, nor anything
%% logged while it was made holds a secret.
without_secrets() ->
    Test = self(),
    Logged = nova_liveboard_test_log:logged(fun() ->
        Infos = nova_liveboard_data:kura_repo_infos(nova_liveboard_data:kura_repos()),
        Test ! {page, page(), printed(Infos)}
    end),
    receive
        {page, Page, Infos} ->
            [
                ?assertEqual(nomatch, binary:match(Shown, Secret))
             || Shown <- [Page, Infos, Logged], Secret <- secrets()
            ],
            Page
    after 0 -> error(page_was_not_rendered)
    end.

secrets() ->
    [list_to_binary(?SECRET), list_to_binary(?IN_URL)].

printed(Term) ->
    iolist_to_binary(io_lib:format("~0tp", [Term])).

page() ->
    iolist_to_binary(nova_liveboard_page_controller:page_inner(database, undefined)).

row(Label, Value) ->
    iolist_to_binary([
        ~"<div class=\"kv\"><span class=\"k\">",
        Label,
        ~"</span><span class=\"v\">",
        Value,
        ~"</span></div>"
    ]).
