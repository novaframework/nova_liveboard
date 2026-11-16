-module(nova_liveboard_csrf_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, nova_liveboard_csrf).
-define(SERVER, nova_liveboard_test_server).
-define(TOKEN, ~"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN-_0").

%% ---------------------------------------------------------------------------
%% token/1
%% ---------------------------------------------------------------------------

token_test_() ->
    {setup, fun() -> application:set_env(nova_liveboard, prefix, ~"/liveboard") end,
        fun(_) -> application:set_env(nova_liveboard, prefix, "/liveboard") end, [
            fun issues_a_random_token_with_a_scoped_cookie/0,
            fun reuses_a_well_formed_cookie/0,
            fun replaces_a_malformed_cookie/0,
            fun marks_the_cookie_secure_over_https/0
        ]}.

issues_a_random_token_with_a_scoped_cookie() ->
    {Token, Req} = ?M:token(req([])),
    {Other, _} = ?M:token(req([])),
    ?assertEqual(43, byte_size(Token)),
    ?assertNotEqual(Token, Other),
    Cookie = set_cookie(Req),
    ?assertMatch(<<"nova_liveboard_csrf=", Token:43/binary, _/binary>>, Cookie),
    ?assert(has(Cookie, ~"; Path=/liveboard")),
    ?assert(has(Cookie, ~"; HttpOnly")),
    ?assert(has(Cookie, ~"; SameSite=Strict")),
    ?assertNot(has(Cookie, ~"; Secure")),
    ?assertNot(has(Cookie, ~"Domain")).

reuses_a_well_formed_cookie() ->
    Req = req([{~"cookie", <<"a=b; nova_liveboard_csrf=", ?TOKEN/binary>>}]),
    ?assertEqual({?TOKEN, Req}, ?M:token(Req)).

replaces_a_malformed_cookie() ->
    [
        begin
            {Token, Req} = ?M:token(req([{~"cookie", Header}])),
            ?assertEqual({Header, 43}, {Header, byte_size(Token)}),
            ?assertMatch(#{resp_cookies := #{~"nova_liveboard_csrf" := _}}, Req)
        end
     || Header <- [
            ~"nova_liveboard_csrf=short",
            <<"nova_liveboard_csrf=", (binary:copy(~"<", 43))/binary>>,
            <<"nova_liveboard_csrf=", ?TOKEN/binary, "x">>,
            ~"nova_liveboard_csrf=",
            ~"=;;=\x00"
        ]
    ].

marks_the_cookie_secure_over_https() ->
    {_, Tls} = ?M:token((req([]))#{scheme => ~"https"}),
    {_, Proxied} = ?M:token(req([{~"x-forwarded-proto", ~"https"}])),
    ?assert(has(set_cookie(Tls), ~"; Secure")),
    ?assert(has(set_cookie(Proxied), ~"; Secure")).

%% ---------------------------------------------------------------------------
%% verify/1
%% ---------------------------------------------------------------------------

verify_test_() ->
    {foreach, fun() -> ok end, fun(_) -> application:unset_env(nova_liveboard, trusted_origins) end,
        [
            {Name, fun() -> ?assertEqual(Expected, ?M:verify(req(Headers))) end}
         || {Name, Expected, Headers} <- verify_cases()
        ] ++
            [
                fun trusted_origin_is_accepted/0,
                fun http2_request_without_host_header/0,
                fun hostile_headers_never_crash/0
            ]}.

verify_cases() ->
    Token = [{~"cookie", <<"nova_liveboard_csrf=", ?TOKEN/binary>>}, {~"x-csrf-token", ?TOKEN}],
    [
        {"fetch metadata same-origin with token", ok, [{~"sec-fetch-site", ~"same-origin"} | Token]},
        {"matching origin with token", ok, [{~"origin", ~"http://board.test"} | Token]},
        {"origin match ignores case", ok, [{~"origin", ~"https://BOARD.test"} | Token]},
        {"fetch metadata wins over a matching origin", {error, cross_site}, [
            {~"sec-fetch-site", ~"cross-site"}, {~"origin", ~"http://board.test"} | Token
        ]},
        {"same-site is not same-origin", {error, cross_site}, [
            {~"sec-fetch-site", ~"same-site"} | Token
        ]},
        {"navigation is refused", {error, cross_site}, [{~"sec-fetch-site", ~"none"} | Token]},
        {"other origin", {error, origin_mismatch}, [{~"origin", ~"https://evil.test"} | Token]},
        {"other port", {error, origin_mismatch}, [{~"origin", ~"http://board.test:8080"} | Token]},
        {"host as a prefix of the origin", {error, origin_mismatch}, [
            {~"origin", ~"http://board.test.evil.test"} | Token
        ]},
        {"opaque origin", {error, origin_mismatch}, [{~"origin", ~"null"} | Token]},
        {"empty origin", {error, origin_mismatch}, [{~"origin", ~""} | Token]},
        {"neither header", {error, origin_missing}, Token},
        {"no cookie", {error, token_missing}, [
            {~"sec-fetch-site", ~"same-origin"}, {~"x-csrf-token", ?TOKEN}
        ]},
        {"no header", {error, token_missing}, [
            {~"sec-fetch-site", ~"same-origin"},
            {~"cookie", <<"nova_liveboard_csrf=", ?TOKEN/binary>>}
        ]},
        {"nothing at all", {error, origin_missing}, []},
        {"different token", {error, token_mismatch}, [
            {~"sec-fetch-site", ~"same-origin"},
            {~"cookie", <<"nova_liveboard_csrf=", ?TOKEN/binary>>},
            {~"x-csrf-token", binary:copy(~"A", 43)}
        ]},
        {"token of another length", {error, token_mismatch}, [
            {~"sec-fetch-site", ~"same-origin"},
            {~"cookie", <<"nova_liveboard_csrf=", ?TOKEN/binary>>},
            {~"x-csrf-token", ~"abc"}
        ]},
        {"empty cookie and empty header do not match", {error, token_missing}, [
            {~"sec-fetch-site", ~"same-origin"},
            {~"cookie", ~"nova_liveboard_csrf="},
            {~"x-csrf-token", ~""}
        ]}
    ].

trusted_origin_is_accepted() ->
    Token = [{~"cookie", <<"nova_liveboard_csrf=", ?TOKEN/binary>>}, {~"x-csrf-token", ?TOKEN}],
    Headers = [{~"origin", ~"http://ops.example.com"} | Token],
    ?assertEqual({error, origin_mismatch}, ?M:verify(req(Headers))),
    application:set_env(nova_liveboard, trusted_origins, [~"http://ops.example.com"]),
    ?assertEqual(ok, ?M:verify(req(Headers))),
    ?assertEqual(
        {error, origin_mismatch},
        ?M:verify(req([{~"origin", ~"http://ops.example.com.evil.test"} | Token]))
    ),
    application:set_env(nova_liveboard, trusted_origins, not_a_list),
    ?assertEqual({error, origin_mismatch}, ?M:verify(req(Headers))).

http2_request_without_host_header() ->
    Token = [{~"cookie", <<"nova_liveboard_csrf=", ?TOKEN/binary>>}, {~"x-csrf-token", ?TOKEN}],
    Req = fun(Origin, Port) ->
        (without_host([{~"origin", Origin} | Token]))#{host => ~"board.test", port => Port}
    end,
    ?assertEqual(ok, ?M:verify(Req(~"https://board.test", 443))),
    ?assertEqual(ok, ?M:verify(Req(~"https://board.test:8443", 8443))),
    ?assertEqual({error, origin_mismatch}, ?M:verify(Req(~"https://board.test", 8443))),
    ?assertEqual({error, origin_mismatch}, ?M:verify(Req(~"https://evil.test", 443))),
    ?assertEqual({error, origin_mismatch}, ?M:verify(without_host([{~"origin", ~"x"} | Token]))).

hostile_headers_never_crash() ->
    [
        ?assertMatch({error, _}, ?M:verify(req([{Name, Value}])))
     || Name <- [~"origin", ~"sec-fetch-site", ~"cookie", ~"x-csrf-token", ~"host"],
        Value <- [<<255, 254>>, ~"", binary:copy(~"a", 100000), <<0>>, ~"=;;=", ~"http://"]
    ],
    ?assertEqual({error, origin_missing}, ?M:verify(maps:without([headers], req([])))).

%% ---------------------------------------------------------------------------
%% over HTTP
%% ---------------------------------------------------------------------------

http_test_() ->
    {setup, fun() -> ?SERVER:start([{prefix, ~"/liveboard"}, {auth, none}]) end, fun ?SERVER:stop/1,
        fun(Server) ->
            [
                {"a page sets the cookie and carries the token", fun() -> page_token(Server) end},
                {"a page reuses the cookie it is sent", fun() -> page_reuse(Server) end},
                {"every action works with the page's token", fun() -> accepted(Server) end},
                {"every action refuses a forged request", fun() -> refused(Server) end}
            ]
        end}.

page_token(Server) ->
    Response = ?SERVER:request(Server, ~"GET /liveboard/processes HTTP/1.1"),
    [<<"nova_liveboard_csrf=", Token:43/binary, "; ", _/binary>> = Cookie] = issued(Response),
    ?assert(has(Cookie, ~"Path=/liveboard")),
    ?assert(has(Cookie, ~"HttpOnly")),
    ?assert(has(Cookie, ~"SameSite=Strict")),
    ?assert(has(?SERVER:body(Response), <<"<body data-liveboard-csrf=\"", Token/binary, "\">">>)),
    ?assertEqual(200, ?SERVER:status(Response)),
    ?assertNotEqual(undefined, ?SERVER:header(~"content-security-policy", Response)).

page_reuse(Server) ->
    Response = ?SERVER:request(Server, ~"GET /liveboard/ HTTP/1.1", [
        {~"cookie", <<"nova_liveboard_csrf=", ?TOKEN/binary>>}
    ]),
    ?assertEqual([], issued(Response)),
    ?assert(has(?SERVER:body(Response), <<"data-liveboard-csrf=\"", ?TOKEN/binary, "\"">>)).

accepted(Server) ->
    Page = ?SERVER:request(Server, ~"GET /liveboard/requests HTTP/1.1"),
    [<<"nova_liveboard_csrf=", Token:43/binary, _/binary>>] = issued(Page),
    Headers = [
        {~"cookie", <<"nova_liveboard_csrf=", Token/binary>>},
        {~"x-csrf-token", Token},
        {~"sec-fetch-site", ~"same-origin"},
        {~"content-length", ~"0"}
    ],
    capture_one_request(),
    Start = post(Server, ~"/liveboard/requests/trace/start", Headers),
    ?assertEqual(200, ?SERVER:status(Start)),
    ?assert(has(?SERVER:body(Start), ~"deep trace armed")),
    ?assertEqual(#{armed => true, remaining => 10}, nova_liveboard_tracer:trace_state()),
    Stop = post(Server, ~"/liveboard/requests/trace/stop", Headers),
    ?assertEqual(200, ?SERVER:status(Stop)),
    ?assertEqual(#{armed => false, remaining => 0}, nova_liveboard_tracer:trace_state()),
    ?assertEqual(1, length(nova_liveboard_tracer:recent())),
    Clear = post(Server, ~"/liveboard/requests/clear", Headers),
    ?assertEqual(200, ?SERVER:status(Clear)),
    ?assertEqual([], nova_liveboard_tracer:recent()).

refused(Server) ->
    Cookie = {~"cookie", <<"nova_liveboard_csrf=", ?TOKEN/binary>>},
    Length = {~"content-length", ~"0"},
    Forgeries = [
        [Length],
        [Length, Cookie],
        [Length, Cookie, {~"origin", ~"https://evil.test"}],
        [Length, Cookie, {~"origin", ~"http://board.test"}],
        [Length, Cookie, {~"sec-fetch-site", ~"same-origin"}],
        [Length, Cookie, {~"x-csrf-token", ?TOKEN}],
        [Length, Cookie, {~"x-csrf-token", ?TOKEN}, {~"sec-fetch-site", ~"cross-site"}],
        [Length, Cookie, {~"x-csrf-token", ?TOKEN}, {~"origin", ~"https://evil.test"}],
        [Length, {~"x-csrf-token", ?TOKEN}, {~"sec-fetch-site", ~"same-origin"}],
        [
            Length,
            Cookie,
            {~"x-csrf-token", binary:copy(~"A", 43)},
            {~"sec-fetch-site", ~"same-origin"}
        ]
    ],
    nova_liveboard_tracer:stop_trace(),
    capture_one_request(),
    [
        ?assertEqual(
            {Path, Headers, 403}, {Path, Headers, ?SERVER:status(post(Server, Path, Headers))}
        )
     || Path <- action_paths(), Headers <- Forgeries
    ],
    ?assertEqual(#{armed => false, remaining => 0}, nova_liveboard_tracer:trace_state()),
    ?assertEqual(1, length(nova_liveboard_tracer:recent())).

action_paths() ->
    [
        ~"/liveboard/requests/trace/start",
        ~"/liveboard/requests/trace/stop",
        ~"/liveboard/requests/clear"
    ].

capture_one_request() ->
    nova_liveboard_tracer:clear(),
    nova_liveboard_tracer:finalize(~"0123456789ab", #{
        id => ~"0123456789ab",
        method => ~"GET",
        path => ~"/api/widgets",
        handler => ~"widgets:index/1",
        status => 200,
        duration_us => 10,
        reductions => 20,
        mem => 30,
        ts => 0
    }).

%% Nova adds a session cookie of its own to the same response.
issued({_Status, Headers, _Body}) ->
    [Value || {~"set-cookie", <<"nova_liveboard_csrf=", _/binary>> = Value} <- Headers].

post(Server, Path, Headers) ->
    ?SERVER:request(Server, [~"POST ", Path, ~" HTTP/1.1"], Headers).

req(Headers) ->
    #{headers => maps:merge(#{~"host" => ~"board.test"}, maps:from_list(Headers))}.

without_host(Headers) ->
    #{headers => maps:from_list(Headers)}.

set_cookie(#{resp_cookies := #{~"nova_liveboard_csrf" := Cookie}}) ->
    iolist_to_binary(Cookie).

has(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.
