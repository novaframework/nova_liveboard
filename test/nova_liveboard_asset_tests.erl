-module(nova_liveboard_asset_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SERVER, nova_liveboard_test_server).

asset_test_() ->
    {setup, fun() -> ?SERVER:start([{prefix, ~"/liveboard"}]) end, fun ?SERVER:stop/1, fun(Server) ->
        [
            {"serves the stylesheet", fun() -> serves_stylesheet(Server) end},
            {"serves the datastar bundle", fun() -> serves_script(Server) end},
            {"serves the fonts", fun() -> serves_fonts(Server) end},
            [
                {binary_to_list(Path), fun() -> escapes_are_not_found(Server, Path) end}
             || Path <- escape_attempts()
            ]
        ]
    end}.

serves_stylesheet(Server) ->
    Response = ?SERVER:request(Server, ~"GET /liveboard/assets/css/app.css HTTP/1.1"),
    ?assertEqual(200, ?SERVER:status(Response)),
    ?assertEqual(~"text/css", ?SERVER:header(~"content-type", Response)),
    ?assertNotEqual(nomatch, binary:match(?SERVER:body(Response), ~".masthead")).

serves_script(Server) ->
    Response = ?SERVER:request(Server, ~"GET /liveboard/assets/js/datastar.js HTTP/1.1"),
    ?assertEqual(200, ?SERVER:status(Response)),
    ?assertNotEqual(nomatch, binary:match(?SERVER:body(Response), ~"Datastar")).

serves_fonts(Server) ->
    [
        begin
            Response = ?SERVER:request(Server, [
                ~"GET /liveboard/assets/fonts/", Font, ~" HTTP/1.1"
            ]),
            ?assertEqual({Font, 200}, {Font, ?SERVER:status(Response)}),
            ?assertMatch(<<"wOF2", _/binary>>, ?SERVER:body(Response))
        end
     || Font <- fonts()
    ].

fonts() ->
    [
        ~"ibm-plex-mono-latin-400-normal.woff2",
        ~"ibm-plex-mono-latin-400-italic.woff2",
        ~"ibm-plex-mono-latin-500-normal.woff2",
        ~"ibm-plex-mono-latin-600-normal.woff2"
    ].

escapes_are_not_found(Server, Path) ->
    Response = ?SERVER:request(Server, [~"GET ", Path, ~" HTTP/1.1"]),
    ?assertEqual({Path, 404}, {Path, ?SERVER:status(Response)}),
    ?assertEqual(nomatch, binary:match(?SERVER:body(Response), ~"erl_opts")),
    ?assertEqual(nomatch, binary:match(?SERVER:body(Response), ~"root:")).

escape_attempts() ->
    [
        ~"/liveboard/assets/../../../rebar.config",
        ~"/liveboard/assets/js/../../../../rebar.config",
        ~"/liveboard/assets/css/../../../../../rebar.config",
        ~"/liveboard/assets/./../../../rebar.config",
        ~"/liveboard/assets/%2e%2e/%2e%2e/%2e%2e/rebar.config",
        ~"/liveboard/assets/%2E%2E/%2E%2E/%2E%2E/rebar.config",
        ~"/liveboard/assets/.%2e/.%2e/.%2e/rebar.config",
        ~"/liveboard/assets/..%2f..%2f..%2frebar.config",
        ~"/liveboard/assets/%2e%2e%2f%2e%2e%2f%2e%2e%2frebar.config",
        ~"/liveboard/assets/..%5c..%5c..%5crebar.config",
        ~"/liveboard/assets/..\\..\\..\\rebar.config",
        ~"/liveboard/assets/%252e%252e/%252e%252e/%252e%252e/rebar.config",
        ~"/liveboard/assets/..;/..;/..;/rebar.config",
        ~"/liveboard/assets//etc/passwd",
        ~"/liveboard/assets/%2fetc%2fpasswd",
        ~"/liveboard/assets/js/datastar.js%00.css",
        ~"/liveboard/assets/js/.datastar.js",
        ~"/liveboard/assets/css/unknown.css"
    ].
