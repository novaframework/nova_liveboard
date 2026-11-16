-module(nova_liveboard_xss_tests).
-moduledoc """
Renders every page with hostile values in every field that is not a number,
then checks the markup structurally: only the tags and attributes the
liveboard itself writes may exist, and Datastar expressions must be the
liveboard's own constants.
""".
-include_lib("eunit/include/eunit.hrl").

-define(HTML, nova_liveboard_html).
-define(OPEN_STREAM,
    ~"@get(el.dataset.liveboardStream, {retry: 'always', retryInterval: 3000})"
).
-define(POST_ACTION,
    ~"@post(el.dataset.liveboardAction, {headers: {'x-csrf-token': document.body.dataset.liveboardCsrf}})"
).

-define(TAGS, [
    ~"!DOCTYPE",
    ~"html",
    ~"head",
    ~"meta",
    ~"title",
    ~"link",
    ~"script",
    ~"body",
    ~"header",
    ~"nav",
    ~"main",
    ~"section",
    ~"div",
    ~"span",
    ~"b",
    ~"p",
    ~"a",
    ~"h2",
    ~"h3",
    ~"pre",
    ~"table",
    ~"thead",
    ~"tbody",
    ~"tr",
    ~"th",
    ~"td",
    ~"button",
    ~"svg",
    ~"polyline"
]).

-define(ATTRIBUTES, [
    ~"html",
    ~"lang",
    ~"charset",
    ~"name",
    ~"content",
    ~"rel",
    ~"href",
    ~"type",
    ~"src",
    ~"class",
    ~"id",
    ~"colspan",
    ~"viewBox",
    ~"preserveAspectRatio",
    ~"points",
    ~"data-liveboard-stream",
    ~"data-liveboard-action",
    ~"data-liveboard-csrf",
    ~"data-init",
    ~"data-on:click"
]).

payloads() ->
    [
        ~"<script>alert(1)</script>",
        ~"\"><img src=x onerror=alert(1)>",
        ~"'><svg onload=alert(1)>",
        ~"');alert(1);//",
        ~"&#39;);alert(1);//",
        ~"&quot; data-on:load=&quot;alert(1)",
        ~"\" data-on:load=\"alert(1)",
        ~"' data-init='alert(1)",
        ~"x\" autofocus onfocus=\"alert(1)",
        ~"\" style=\"position:fixed",
        ~"${alert(1)}",
        ~"`+alert(1)+`",
        ~"</td></tr></table><script>alert(1)</script>",
        ~"</pre><script>alert(1)</script>",
        ~"javascript:alert(1)",
        ~"../../requests/clear?",
        ~"a/b?c=d#e",
        ~"\\');alert(1);//",
        ~"/x\rdata: selector body\r\rdata: mode remove",
        <<"q", 0, "\r\n<script>alert(1)</script>">>,
        <<255, 254, "<script>alert(1)</script>">>
    ].

structure_test_() ->
    {setup,
        fun() ->
            application:set_env(nova_liveboard, prefix, ~"/liveboard"),
            {ok, Tracer} = nova_liveboard_tracer:start_link(),
            Tracer
        end,
        fun(Tracer) ->
            gen_server:stop(Tracer),
            application:set_env(nova_liveboard, prefix, "/liveboard")
        end,
        [
            {Name, fun() -> check(Render(Payload)) end}
         || Payload <- payloads(), {Name, Render} <- renderers()
        ]}.

renderers() ->
    [
        {"overview", fun(X) -> ?HTML:overview_html(system(X)) end},
        {"processes", fun(X) -> ?HTML:processes_html([process(X)], memory) end},
        {"ets", fun(X) -> ?HTML:ets_html([table(X)]) end},
        {"applications", fun(X) ->
            ?HTML:apps_html([#{name => X, version => X, description => X}])
        end},
        {"ports", fun(X) ->
            ?HTML:ports_html([#{id => X, name => X, connected => X, input => 1, output => 2}])
        end},
        {"supervisors", fun(X) ->
            ?HTML:sup_tree_html([named(X), kernel], named(X), {ok, [child(X)]})
        end},
        {"supervisors without a tree", fun(X) ->
            ?HTML:sup_tree_html([named(X)], named(X), {error, X})
        end},
        {"requests", fun(X) ->
            ?HTML:requests_html([request(X)], #{armed => true, remaining => 3}, true)
        end},
        {"request row", fun(X) -> ?HTML:request_row(request(X)) end},
        {"request detail", fun(X) -> ?HTML:request_detail_html(request(X)) end},
        {"database", fun(X) -> ?HTML:database_html([repo(X)]) end},
        {"database figures", fun(X) -> ?HTML:database_html([repo_with_figures(X)]) end},
        {"schemas", fun(X) -> ?HTML:schemas_html([schema(X)]) end},
        {"page shell", fun(X) ->
            ?HTML:page(
                requests,
                ~"/liveboard/sse/requests",
                ?HTML:vitals_html(nova_liveboard_data:system_info()),
                ?HTML:request_row(request(X)),
                X
            )
        end},
        {"processes page from a hostile query string", fun(X) ->
            body(nova_liveboard_page_controller:processes(#{qs => cow_qs:qs([{~"sort", X}])}))
        end},
        {"supervisors page from a hostile query string", fun(X) ->
            body(nova_liveboard_page_controller:supervisors(#{qs => cow_qs:qs([{~"app", X}])}))
        end},
        {"request page from a hostile id", fun(X) ->
            body(nova_liveboard_page_controller:request_show(#{bindings => #{~"id" => X}}))
        end}
    ].

body(Reply) ->
    ?assertEqual(status, element(1, Reply)),
    ?assertEqual(200, element(2, Reply)),
    element(4, Reply).

system(X) ->
    (nova_liveboard_data:system_info())#{
        otp_release => X, erts_version => X, system_architecture => X
    }.

process(X) ->
    #{
        pid => X,
        name => X,
        memory => 2048,
        reductions => 1500,
        message_queue_len => 0,
        current_function => X
    }.

table(X) ->
    #{
        name => X,
        id => X,
        type => X,
        protection => X,
        size => 3,
        memory_bytes => 4096,
        owner => X
    }.

child(X) ->
    #{
        type => supervisor,
        name => X,
        pid => X,
        status => X,
        memory => 1024,
        children => [
            #{type => worker, name => X, pid => X, status => ~"running", children => []}
        ]
    }.

request(X) ->
    #{
        id => X,
        method => X,
        path => X,
        status => X,
        duration_us => 850,
        reductions => 4200,
        mem => 4096,
        handler => X,
        spawned => 1,
        spawned_tree => [#{pid => X, mfa => X, parent => X, depth => 1}]
    }.

repo(X) ->
    #{
        module => X,
        database => X,
        host => X,
        port => X,
        configured_size => X,
        pool => #{status => X, backend => X, name => X, reason => X}
    }.

repo_with_figures(X) ->
    Repo = repo(X),
    Repo#{
        pool => #{
            status => X,
            backend => X,
            name => X,
            figures => #{size => X, in_use => X, idle => X, waiting => X, counters => [{X, X}]}
        }
    }.

schema(X) ->
    #{
        module => X,
        table => X,
        fields => [#{name => X, type => X, primary_key => true, virtual => true}]
    }.

named(X) ->
    binary_to_atom(printable(X)).

printable(X) ->
    case unicode:characters_to_binary(X) of
        X -> X;
        _ -> ~"<script>alert(1)</script>"
    end.

%% ---------------------------------------------------------------------------
%% structural check
%% ---------------------------------------------------------------------------

check(IoData) ->
    Html = iolist_to_binary(IoData),
    Tags = tags(Html),
    ?assertEqual(count(Html, ~"<"), length(Tags)),
    ?assertEqual(count(Html, ~">"), length(Tags)),
    ?assertEqual(0, count(Html, ~"\r")),
    [check_tag(Tag) || Tag <- Tags],
    ok.

check_tag({closing, Name}) ->
    ?assert(lists:member(Name, ?TAGS));
check_tag({opening, Name, Attributes}) ->
    ?assertEqual({Name, true}, {Name, lists:member(Name, ?TAGS)}),
    [check_attribute(Attribute) || Attribute <- Attributes].

check_attribute({Name, Value}) ->
    ?assertEqual({Name, true}, {Name, lists:member(Name, ?ATTRIBUTES)}),
    check_value(Name, Value).

check_value(~"data-init", Value) ->
    ?assertEqual(?OPEN_STREAM, unescape(Value));
check_value(~"data-on:click", Value) ->
    ?assertEqual(?POST_ACTION, unescape(Value));
check_value(Name, Value) when
    Name =:= ~"data-liveboard-action";
    Name =:= ~"data-liveboard-stream";
    Name =:= ~"href";
    Name =:= ~"src"
->
    Url = unescape(Value),
    ?assertEqual(
        {Url, match},
        {Url,
            re:run(Url, ~"^/liveboard(/[A-Za-z0-9._~%-]*)*(\\?[A-Za-z0-9._~%=&-]*)?$", [
                {capture, none}
            ])}
    );
check_value(~"class", Value) ->
    ?assertEqual({Value, match}, {Value, re:run(Value, ~"^[a-z0-9 -]*$", [{capture, none}])});
check_value(_Name, _Value) ->
    ok.

tags(Html) ->
    Pattern =
        ~"<(/?)([A-Za-z!][A-Za-z0-9]*)((?:\\s+[^\\s=<>\"']+(?:=\"[^\"<>]*\")?)*)\\s*>",
    case re:run(Html, Pattern, [global, {capture, all_but_first, binary}]) of
        {match, Matches} -> [tag(Match) || Match <- Matches];
        nomatch -> []
    end.

tag([~"/", Name, _Attributes]) ->
    {closing, Name};
tag([~"", Name, Attributes]) ->
    {opening, Name, attributes(Attributes)}.

attributes(Raw) ->
    case
        re:run(Raw, ~"\\s+([^\\s=<>\"']+)(?:=\"([^\"<>]*)\")?", [
            global, {capture, all_but_first, binary}
        ])
    of
        {match, Matches} -> [attribute(Match) || Match <- Matches];
        nomatch -> []
    end.

attribute([Name]) -> {Name, ~""};
attribute([Name, Value]) -> {Name, Value}.

unescape(Value) ->
    unescape(Value, [
        {~"&lt;", ~"<"}, {~"&gt;", ~">"}, {~"&quot;", ~"\""}, {~"&#39;", ~"'"}, {~"&amp;", ~"&"}
    ]).

unescape(Value, []) ->
    Value;
unescape(Value, [{Entity, Char} | Rest]) ->
    unescape(binary:replace(Value, Entity, Char, [global]), Rest).

count(Html, Needle) ->
    length(binary:matches(Html, Needle)).

%% ---------------------------------------------------------------------------
%% the specific defects
%% ---------------------------------------------------------------------------

escape_is_total_test_() ->
    [
        ?_assertEqual(~"&amp;&lt;&gt;&quot;&#39;&#13;", ?HTML:html_escape(~"&<>\"'\r")),
        ?_assertEqual(~"&lt;b&gt;", ?HTML:html_escape("<b>")),
        ?_assertEqual(~"a&lt;b&gt;c", ?HTML:html_escape([~"a", "<b>", $c])),
        ?_assertEqual(~"{&lt;&lt;&quot;&lt;b&gt;&quot;&gt;&gt;,1}", ?HTML:html_escape({~"<b>", 1})),
        ?_assertEqual(~"[a,&lt;&lt;&quot;&lt;&quot;&gt;&gt;]", ?HTML:html_escape([a, ~"<"])),
        ?_assertEqual(~"&lt;", ?HTML:html_escape('<')),
        ?_assertEqual(<<255, "&lt;">>, ?HTML:html_escape(<<255, "<">>))
    ].

printed_terms_are_bounded_test() ->
    Printed = ?HTML:html_escape({lists:duplicate(5000, $a), lists:seq(1, 5000)}),
    ?assert(byte_size(Printed) < 1000).

overview_values_are_escaped_test() ->
    Html = iolist_to_binary(?HTML:overview_html(system(~"<img src=x onerror=alert(1)>"))),
    ?assertEqual(nomatch, binary:match(Html, ~"<img")),
    ?assertEqual(3, count(Html, ~"&lt;img src=x onerror=alert(1)&gt;")).

kura_config_is_escaped_test() ->
    Html = iolist_to_binary(?HTML:database_html([repo(~"<script>alert(1)</script>")])),
    ?assertEqual(nomatch, binary:match(Html, ~"<script>")),
    ?assertEqual(9, count(Html, ~"&lt;script&gt;")).

kura_pool_figures_are_escaped_test() ->
    Html = iolist_to_binary(
        ?HTML:database_html([repo_with_figures(~"<script>alert(1)</script>")])
    ),
    ?assertEqual(nomatch, binary:match(Html, ~"<script>")),
    ?assertEqual(13, count(Html, ~"&lt;script&gt;")).

request_id_never_reaches_a_url_unencoded_test() ->
    application:set_env(nova_liveboard, prefix, ~"/liveboard"),
    Row = iolist_to_binary(?HTML:request_row(request(~"x\" onclick=\"alert(1)"))),
    application:set_env(nova_liveboard, prefix, "/liveboard"),
    ?assertNotEqual(
        nomatch,
        binary:match(Row, ~"href=\"/liveboard/requests/x%22%20onclick%3D%22alert%281%29\"")
    ).

app_name_is_encoded_in_links_test() ->
    application:set_env(nova_liveboard, prefix, ~"/liveboard"),
    App = 'a&b=c d',
    Html = iolist_to_binary(?HTML:sup_tree_html([App], App, {error, no_supervisor})),
    application:set_env(nova_liveboard, prefix, "/liveboard"),
    ?assertNotEqual(
        nomatch, binary:match(Html, ~"href=\"/liveboard/supervisors?app=a%26b%3Dc%20d\"")
    ),
    ?assertNotEqual(nomatch, binary:match(Html, ~">a&amp;b=c d</a>")).

actions_are_constant_expressions_test() ->
    application:set_env(nova_liveboard, prefix, ~"/live');alert(1);//"),
    Html = iolist_to_binary(?HTML:requests_toolbar_html(#{armed => false, remaining => 0})),
    Page = iolist_to_binary(?HTML:page(overview, ~"/x');alert(1);//", ~"", ~"", ~"t")),
    application:set_env(nova_liveboard, prefix, "/liveboard"),
    ?assertEqual(nomatch, binary:match(Html, ~"@post('")),
    ?assertEqual(nomatch, binary:match(Page, ~"@get('")),
    ?assertEqual(3, count(Html, <<"data-on:click=\"", ?POST_ACTION/binary, "\"">>)),
    ?assertEqual(2, count(Page, <<"data-init=\"", ?OPEN_STREAM/binary, "\"">>)),
    ?assertNotEqual(
        nomatch,
        binary:match(
            Html, ~"data-liveboard-action=\"/live&#39;);alert(1);///requests/trace/start\""
        )
    ),
    ?assertNotEqual(
        nomatch, binary:match(Page, ~"data-liveboard-stream=\"/x&#39;);alert(1);//\"")
    ).

no_inline_styles_test() ->
    Sys = nova_liveboard_data:system_info(),
    Pages = [
        ?HTML:vitals_html(Sys),
        ?HTML:overview_html(Sys),
        ?HTML:metrics_html(nova_liveboard_data:collect_metrics(undefined)),
        ?HTML:sup_tree_html([kernel], kernel, {ok, [child(~"c")]}),
        ?HTML:request_detail_html(request(~"r"))
    ],
    [?assertEqual(nomatch, binary:match(iolist_to_binary(Page), ~"style=")) || Page <- Pages],
    Tree = iolist_to_binary(?HTML:sup_tree_html([kernel], kernel, {ok, [child(~"c")]})),
    ?assertNotEqual(nomatch, binary:match(Tree, ~"class=\"node d-0\"")),
    ?assertNotEqual(nomatch, binary:match(Tree, ~"class=\"node d-1\"")),
    ?assertNotEqual(nomatch, binary:match(iolist_to_binary(?HTML:overview_html(Sys)), ~" w-")).

every_width_and_depth_class_has_a_rule_test() ->
    _ = application:load(nova_liveboard),
    {ok, Css} = file:read_file(
        filename:join(code:priv_dir(nova_liveboard), "static/assets/css/app.css")
    ),
    [
        ?assertNotEqual(
            {N, nomatch},
            {N, binary:match(Css, iolist_to_binary(io_lib:format(".fill.w-~b{width:~b%}", [N, N])))}
        )
     || N <- lists:seq(0, 100)
    ],
    [
        ?assertNotEqual(
            {N, nomatch},
            {N,
                binary:match(
                    Css, iolist_to_binary(io_lib:format(".node.d-~b{--depth:~b}", [N, N]))
                )}
        )
     || N <- lists:seq(0, 16)
    ],
    Deep = iolist_to_binary(
        ?HTML:request_detail_html((request(~"r"))#{
            spawned_tree => [#{pid => ~"p", mfa => ~"m", parent => ~"q", depth => 400}]
        })
    ),
    ?assertNotEqual(nomatch, binary:match(Deep, ~"class=\"node d-16\"")).

uri_encode_is_total_test() ->
    ?assertEqual(~"a-b_c.d~e", ?HTML:uri_encode(~"a-b_c.d~e")),
    ?assertEqual(~"a%2Fb%20c%3F%27%22%3C%3E%25", ?HTML:uri_encode(~"a/b c?'\"<>%")),
    ?assertEqual(~"%FF%FE%00", ?HTML:uri_encode(<<255, 254, 0>>)),
    ?assertEqual(~"%C3%A5", ?HTML:uri_encode(~"å")).

policy_test() ->
    #{~"content-security-policy" := Policy} = Headers = ?HTML:csp_headers(),
    ?assertNotEqual(nomatch, binary:match(Policy, ~"default-src 'none'")),
    ?assertNotEqual(nomatch, binary:match(Policy, ~"script-src 'self' 'unsafe-eval';")),
    ?assertNotEqual(nomatch, binary:match(Policy, ~"style-src 'self';")),
    ?assertNotEqual(nomatch, binary:match(Policy, ~"font-src 'self';")),
    ?assertNotEqual(nomatch, binary:match(Policy, ~"img-src 'self' data:;")),
    ?assertEqual(nomatch, binary:match(Policy, ~"unsafe-inline")),
    ?assertEqual(nomatch, binary:match(Policy, ~"*")),
    ?assertEqual(1, count(Policy, ~"data:")),
    ?assertNotEqual(nomatch, binary:match(Policy, ~"frame-ancestors 'none'")),
    ?assertNotEqual(nomatch, binary:match(Policy, ~"base-uri 'none'")),
    ?assertNotEqual(nomatch, binary:match(Policy, ~"form-action 'self'")),
    ?assertEqual(~"nosniff", maps:get(~"x-content-type-options", Headers)),
    ?assertEqual(~"DENY", maps:get(~"x-frame-options", Headers)),
    ?assertEqual(~"no-store", maps:get(~"cache-control", Headers)).

frames_never_carry_a_bare_carriage_return_test() ->
    Row = ?HTML:request_row(request(~"/x\rdata: selector body\r\rdata: mode remove")),
    Frame = iolist_to_binary(
        datastar:patch_elements(Row, #{selector => ~"#req-feed", mode => prepend})
    ),
    ?assertEqual(nomatch, binary:match(Frame, ~"\r")),
    ?assertEqual(
        [
            ~"event: datastar-patch-elements",
            ~"data: selector #req-feed",
            ~"data: mode prepend",
            ~"data: elements"
        ],
        lists:uniq([
            hd(binary:split(Line, ~" <"))
         || Line <- binary:split(Frame, ~"\n", [global]), Line =/= ~""
        ])
    ).
