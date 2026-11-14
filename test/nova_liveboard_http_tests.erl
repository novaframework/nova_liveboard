-module(nova_liveboard_http_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SERVER, nova_liveboard_test_server).

http_test_() ->
    {setup, fun() -> ?SERVER:start([{prefix, ~"/liveboard"}, {refresh_ms, 50}]) end,
        fun ?SERVER:stop/1, fun(Server) ->
            [
                {"pages render under the prefix", fun() -> pages_render(Server) end},
                {"the stream sends datastar patches", fun() -> stream_patches(Server) end},
                {"unknown paths are not found", fun() -> unknown_is_not_found(Server) end}
            ]
        end}.

pages_render(Server) ->
    [
        ?assertEqual(
            {Path, 200}, {Path, ?SERVER:status(?SERVER:request(Server, get_request(Path)))}
        )
     || Path <- [
            ~"/liveboard/",
            ~"/liveboard/processes",
            ~"/liveboard/ets",
            ~"/liveboard/applications",
            ~"/liveboard/ports",
            ~"/liveboard/supervisors",
            ~"/liveboard/metrics",
            ~"/liveboard/database",
            ~"/liveboard/schemas",
            ~"/liveboard/requests",
            ~"/liveboard/requests/0123456789ab"
        ]
    ],
    Response = ?SERVER:request(Server, get_request(~"/liveboard/ets")),
    ?assertMatch(<<"text/html", _/binary>>, ?SERVER:header(~"content-type", Response)),
    ?assertNotEqual(undefined, ?SERVER:header(~"content-security-policy", Response)),
    ?assertNotEqual(nomatch, binary:match(?SERVER:body(Response), ~"/liveboard/sse/ets")).

stream_patches(Server) ->
    Socket = ?SERVER:open(Server, [
        get_request(~"/liveboard/sse/ets"), ~"\r\nhost: board.test\r\n\r\n"
    ]),
    {open, Bytes} = ?SERVER:read(Socket, 500),
    ok = gen_tcp:close(Socket),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Bytes),
    ?assertNotEqual(nomatch, binary:match(Bytes, ~"text/event-stream")),
    ?assertNotEqual(nomatch, binary:match(Bytes, ~"datastar-patch-elements")),
    ?assertNotEqual(nomatch, binary:match(Bytes, ~"selector #page")).

unknown_is_not_found(Server) ->
    ?assertEqual(404, ?SERVER:status(?SERVER:request(Server, get_request(~"/liveboard/nope")))),
    ?assertEqual(404, ?SERVER:status(?SERVER:request(Server, get_request(~"/")))).

get_request(Path) ->
    [~"GET ", Path, ~" HTTP/1.1"].
