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
