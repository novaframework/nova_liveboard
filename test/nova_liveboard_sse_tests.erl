-module(nova_liveboard_sse_tests).
-include_lib("eunit/include/eunit.hrl").

contains(Hay, Needle) -> binary:match(iolist_to_binary(Hay), Needle) =/= nomatch.

%% The SSE module turns html renders into Datastar patch frames; assert the
%% wire shape it relies on is well-formed.
request_frame_is_valid_sse_test() ->
    R = #{
        id => ~"abc",
        method => ~"GET",
        path => ~"/api/x",
        status => 200,
        duration_us => 500,
        reductions => 1000,
        handler => ~"m:f/1",
        spawned => 2
    },
    Frame = datastar:patch_elements(
        nova_liveboard_html:request_row(R), #{selector => ~"#req-feed", mode => prepend}
    ),
    ?assert(contains(Frame, ~"event: datastar-patch-elements")),
    ?assert(contains(Frame, ~"data: selector #req-feed")),
    ?assert(contains(Frame, ~"data: mode prepend")),
    ?assert(contains(Frame, ~"data: elements")),
    ?assert(contains(Frame, ~"/api/x")).

stream_returns_stream_tuple_test() ->
    Req = #{bindings => #{~"page" => ~"overview"}, qs => ~""},
    {stream, 200, Headers, {Page, Qs}} = nova_liveboard_sse:stream(Req),
    ?assertEqual(~"overview", Page),
    ?assertEqual([], Qs),
    ?assertEqual(~"text/event-stream", maps:get(~"content-type", Headers)).

stream_defaults_page_when_missing_test() ->
    Req = #{bindings => #{}, qs => ~""},
    {stream, 200, _Headers, {Page, _Qs}} = nova_liveboard_sse:stream(Req),
    ?assertEqual(~"overview", Page).
