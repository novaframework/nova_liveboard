-module(nova_liveboard_asset_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SERVER, nova_liveboard_test_server).

asset_test_() ->
    {setup, fun() -> ?SERVER:start([{prefix, ~"/liveboard"}, {auth, none}]) end, fun ?SERVER:stop/1,
        fun(Server) ->
            [
                {"serves the stylesheet", fun() -> serves_stylesheet(Server) end},
                {"serves the datastar bundle", fun() -> serves_script(Server) end},
                {"serves the fonts", fun() -> serves_fonts(Server) end},
                {"only GET is routed", fun() -> only_get(Server) end},
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
    ?assertEqual(~"nosniff", ?SERVER:header(~"x-content-type-options", Response)),
    ?assertNotEqual(nomatch, binary:match(?SERVER:body(Response), ~".masthead")).

serves_script(Server) ->
    Response = ?SERVER:request(Server, ~"GET /liveboard/assets/js/datastar.js HTTP/1.1"),
    ?assertEqual(200, ?SERVER:status(Response)),
    ?assertEqual(~"text/javascript", ?SERVER:header(~"content-type", Response)),
    ?assertEqual(~"nosniff", ?SERVER:header(~"x-content-type-options", Response)),
    ?assertNotEqual(nomatch, binary:match(?SERVER:body(Response), ~"Datastar")).

serves_fonts(Server) ->
    [
        begin
            Response = ?SERVER:request(Server, [
                ~"GET /liveboard/assets/fonts/", Font, ~" HTTP/1.1"
            ]),
            ?assertEqual({Font, 200}, {Font, ?SERVER:status(Response)}),
            ?assertEqual(~"font/woff2", ?SERVER:header(~"content-type", Response)),
            ?assertEqual(~"nosniff", ?SERVER:header(~"x-content-type-options", Response)),
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

only_get(Server) ->
    [
        ?assertEqual(
            {Path, 405},
            {Path,
                ?SERVER:status(
                    ?SERVER:request(Server, [~"POST ", Path, ~" HTTP/1.1"], [
                        {~"content-length", ~"0"}
                    ])
                )}
        )
     || Path <- [
            ~"/liveboard/assets/js/datastar.js",
            ~"/liveboard/assets/css/app.css",
            ~"/liveboard/assets/fonts/ibm-plex-mono-latin-400-normal.woff2"
        ]
    ].

assets_resolve_inside_priv_test() ->
    _ = application:load(nova_liveboard),
    Dir = code:priv_dir(nova_liveboard),
    ?assert(is_list(Dir)),
    PrivDir = filename:absname(lists:flatten(io_lib:format(~"~ts", [Dir]))),
    Assets = [
        nova_liveboard_asset_controller:stylesheet(#{}),
        nova_liveboard_asset_controller:script(#{})
        | [
            nova_liveboard_asset_controller:font(#{bindings => #{~"font" => Font}})
         || Font <- fonts()
        ]
    ],
    ?assertEqual(6, length(Assets)),
    [
        begin
            {sendfile, 200, _Headers, {0, Size, Path}, _ContentType} = Asset,
            ?assert(Size > 0),
            ?assertNotEqual(nomatch, string:prefix(filename:absname(Path), PrivDir)),
            ?assertEqual(nomatch, string:find(Path, ".."))
        end
     || Asset <- Assets
    ].

every_bundled_file_has_a_route_test() ->
    _ = application:load(nova_liveboard),
    Bundled = filelib:wildcard("static/assets/**/*.{css,js,woff2}", code:priv_dir(nova_liveboard)),
    ?assertEqual(6, length(Bundled)).

the_font_notice_describes_the_bundled_fonts_test() ->
    _ = application:load(nova_liveboard),
    Fonts = filename:join([code:priv_dir(nova_liveboard), "static", "assets", "fonts"]),
    {ok, Notice} = file:read_file(filename:join(Fonts, "NOTICE")),
    Bundled = [unicode:characters_to_binary(Name) || Name <- filelib:wildcard("*.woff2", Fonts)],
    {match, Named} = re:run(Notice, ~"[a-z0-9-]+\\.woff2", [global, {capture, first, binary}]),
    ?assertEqual(lists:sort(Bundled), lists:sort(lists:append(Named))),
    ?assertEqual(4, length(Bundled)),
    ?assertEqual(lists:sort(Bundled), lists:sort(fonts())),
    [
        ?assertNotEqual({Stated, nomatch}, {Stated, binary:match(Notice, Stated)})
     || Stated <- [
            ~"nova_liveboard",
            ~"IBM Plex Mono",
            ~"Copyright © 2017 IBM Corp. with Reserved Font Name \"Plex\"",
            ~"SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007",
            ~"PERMISSION & CONDITIONS",
            ~"TERMINATION",
            ~"DISCLAIMER"
        ]
    ],
    [
        ?assertEqual({Absent, nomatch}, {Absent, binary:match(Notice, Absent)})
     || Absent <- [~"gakudan", ~"Instrument", ~"fetch-fonts", ~"make fonts"]
    ].

font_names_are_a_closed_set_test_() ->
    [
        ?_assertEqual(
            {status, 404}, nova_liveboard_asset_controller:font(#{bindings => #{~"font" => Name}})
        )
     || Name <- [
            ~"NOTICE",
            ~"..",
            ~"../css/app.css",
            ~"..%2fcss%2fapp.css",
            ~"ibm-plex-mono-latin-400-normal.woff2/..",
            ~"",
            undefined
        ]
    ] ++ [?_assertEqual({status, 404}, nova_liveboard_asset_controller:font(#{}))].

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
        ~"/liveboard/assets/js/datastar.js/..",
        ~"/liveboard/assets/js/.datastar.js",
        ~"/liveboard/assets/js",
        ~"/liveboard/assets/js/",
        ~"/liveboard/assets/",
        ~"/liveboard/assets",
        ~"/liveboard/assets/css/unknown.css",
        ~"/liveboard/assets/fonts/NOTICE",
        ~"/liveboard/assets/fonts/..%2fcss%2fapp.css",
        ~"/liveboard/assets/fonts/%2e%2e/css/app.css",
        ~"/liveboard/assets/fonts/unknown.woff2"
    ].
