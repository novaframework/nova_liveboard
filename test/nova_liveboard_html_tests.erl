-module(nova_liveboard_html_tests).
-include_lib("eunit/include/eunit.hrl").

bin(IoData) -> iolist_to_binary(IoData).

contains(Hay, Needle) -> binary:match(bin(Hay), Needle) =/= nomatch.

count(Hay, Needle) -> length(binary:matches(bin(Hay), Needle)).

%% ---- escaping ----

html_escape_test_() ->
    [
        ?_assertEqual(~"&amp;&lt;&gt;&quot;", nova_liveboard_html:html_escape(~"&<>\"")),
        ?_assertEqual(~"plain", nova_liveboard_html:html_escape(~"plain")),
        ?_assertEqual(~"42", nova_liveboard_html:html_escape(42)),
        ?_assertEqual(~"an_atom", nova_liveboard_html:html_escape(an_atom))
    ].

escape_blocks_injection_test() ->
    Out = bin(nova_liveboard_html:html_escape(~"<script>alert(1)</script>")),
    ?assertNot(contains(Out, ~"<script>")),
    ?assert(contains(Out, ~"&lt;script&gt;")).

%% ---- document shell ----

csp_headers_test() ->
    H = nova_liveboard_html:csp_headers(),
    Csp = maps:get(~"content-security-policy", H),
    ?assert(contains(Csp, ~"default-src 'self'")),
    ?assert(contains(Csp, ~"frame-ancestors 'none'")),
    ?assertEqual(~"text/html; charset=utf-8", maps:get(~"content-type", H)).

page_includes_assets_and_nav_test() ->
    Out = bin(nova_liveboard_html:page(overview, ~"/liveboard/sse/overview", ~"V", ~"M")),
    ?assert(contains(Out, ~"<!DOCTYPE html>")),
    ?assert(contains(Out, ~"/assets/js/datastar.js")),
    ?assert(contains(Out, ~"/assets/css/app.css")),
    ?assert(contains(Out, ~"Processes")),
    ?assert(contains(Out, ~"id=\"page\"")),
    ?assert(contains(Out, ~"/liveboard/sse/overview")).

live_page_has_main_stream_static_does_not_test() ->
    Live = nova_liveboard_html:page(overview, ~"/liveboard/sse/overview", ~"V", ~"M"),
    Static = nova_liveboard_html:page(requests, none, ~"V", ~"M"),
    %% live = vitals stream + main stream; static = vitals stream only
    ?assertEqual(2, count(Live, ~"data-init")),
    ?assertEqual(1, count(Static, ~"data-init")).

%% ---- regions ----

vitals_and_overview_render_test() ->
    Sys = nova_liveboard_data:system_info(),
    ?assert(contains(nova_liveboard_html:vitals_html(Sys), ~"processes")),
    Ov = nova_liveboard_html:overview_html(Sys),
    ?assert(contains(Ov, ~"otp release")),
    ?assert(contains(Ov, ~"memory")).

processes_render_with_sort_test() ->
    Procs = [
        #{
            pid => ~"<0.1.0>",
            name => ~"some_proc",
            memory => 2048,
            reductions => 1500,
            message_queue_len => 0,
            current_function => ~"m:f/1"
        }
    ],
    Out = bin(nova_liveboard_html:processes_html(Procs, reductions)),
    ?assert(contains(Out, ~"some_proc")),
    ?assert(contains(Out, ~"2.0 KB")),
    %% the active sort chip links carry the sort query
    ?assert(contains(Out, ~"sort=reductions")).

requests_setup_hint_when_disabled_test() ->
    Out = bin(nova_liveboard_html:requests_html([], #{}, false)),
    ?assert(contains(Out, ~"request tracing is off")),
    ?assert(contains(Out, ~"nova_liveboard_trace_plugin")).

requests_feed_when_enabled_test() ->
    R = sample_request(),
    Out = bin(nova_liveboard_html:requests_html([R], #{armed => false, remaining => 0}, true)),
    ?assert(contains(Out, ~"id=\"req-feed\"")),
    ?assert(contains(Out, ~"id=\"req-toolbar\"")),
    ?assert(contains(Out, ~"/api/widgets")),
    ?assert(contains(Out, ~"deep trace off")).

request_row_escapes_path_test() ->
    R = (sample_request())#{path => ~"/x?<b>"},
    Out = bin(nova_liveboard_html:request_row(R)),
    ?assertNot(contains(Out, ~"<b>")),
    ?assert(contains(Out, ~"&lt;b&gt;")).

request_detail_renders_spawn_tree_test() ->
    R = #{
        method => ~"GET",
        path => ~"/api/widgets",
        status => 200,
        duration_us => 1500,
        reductions => 9000,
        mem => 4096,
        handler => ~"my_ctrl:index/1",
        spawned_tree => [
            #{pid => ~"<0.99.0>", mfa => ~"worker:run/0", parent => ~"<0.1.0>", depth => 1}
        ]
    },
    Out = bin(nova_liveboard_html:request_detail_html(R)),
    ?assert(contains(Out, ~"worker:run/0")),
    ?assert(contains(Out, ~"spawned processes (1)")),
    ?assert(contains(Out, ~"1.5 ms")).

request_detail_missing_test() ->
    ?assert(contains(nova_liveboard_html:request_detail_html(undefined), ~"not found")).

sup_tree_render_test() ->
    Tree = [
        #{
            type => worker,
            name => ~"w1",
            pid => ~"<0.10.0>",
            status => ~"running",
            memory => 1024,
            children => []
        }
    ],
    Out = bin(nova_liveboard_html:sup_tree_html([kernel, stdlib], kernel, {ok, Tree})),
    ?assert(contains(Out, ~"w1")),
    ?assert(contains(Out, ~"supervision tree")),
    %% app chooser chip present
    ?assert(contains(Out, ~"?app=kernel")).

sup_tree_error_test() ->
    Out = bin(nova_liveboard_html:sup_tree_html([foo], foo, {error, no_supervisor})),
    ?assert(contains(Out, ~"no supervisor found")).

sample_request() ->
    #{
        id => ~"abc123",
        method => ~"GET",
        path => ~"/api/widgets",
        status => 200,
        duration_us => 850,
        reductions => 4200,
        handler => ~"widgets_ctrl:index/1",
        spawned => 0
    }.
