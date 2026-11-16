-module(nova_liveboard_sse).
-moduledoc """
The liveboard's live transport: one SSE stream per page region.

`stream/1` is a normal Nova controller returning `{stream, Code, Headers,
Source}`. That tuple is picked up by a return-handler we register
(`handle_stream/3`). It answers 404 for a page that has no live region, 503
when `max_streams` streams are already open and 429 when the client that asks
already has `max_streams_per_client` of them; otherwise it subscribes to
`m:nova_liveboard_poller`, `stream_reply`s the SSE headers and then **holds
the connection**, forwarding the frames the poller sends. It never returns, so
Nova's buffered `render_response` (which would reply again and crash) never
runs. See novaframework/nova#387.

The stream does no rendering of its own. Per-connection state (the process
sort order, the application whose supervisors are shown) rides as query params
on the stream URL and becomes the view it subscribes to, so viewers of the
same view share one render.

A stream ends after `stream_lifetime_ms`, whatever the client does. The page
opens it with Datastar's `retry: 'always'`, so the browser reconnects and the
host's auth callback runs again: a revoked session loses its live view within
one lifetime. The connection's idle timeout is raised to match, so the
lifetime and not Cowboy's default decides when an HTTP/1.1 stream ends. A
stream whose client reads too slowly only ever holds the most recent frame.

The handler is registered as an explicit `fun/3` because current Nova invokes
return-handlers with 3 args, while its `{Mod, Fun}` form wraps to arity 4.
""".

-export([register/0, stream/1, handle_stream/3, client/1]).

-define(PAGES, #{
    ~"vitals" => vitals,
    ~"overview" => overview,
    ~"metrics" => metrics,
    ~"requests" => requests,
    ~"ets" => ets,
    ~"applications" => applications,
    ~"ports" => ports,
    ~"database" => database,
    ~"schemas" => schemas
}).
-define(IDLE_MARGIN_MS, 5000).

-spec register() -> ok | {error, atom()}.
register() ->
    nova_handlers:register_handler(stream, fun ?MODULE:handle_stream/3).

%% Nova controller: GET <prefix>/sse/:page
stream(Req) ->
    Page = maps:get(~"page", maps:get(bindings, Req, #{}), ~"overview"),
    Qs = cowboy_req:parse_qs(Req),
    {stream, 200, headers(), {Page, Qs}}.

handle_stream({stream, Code, Headers, {Name, Qs}}, Callback, Req) ->
    case view(Name, Qs) of
        {ok, View} ->
            case nova_liveboard_poller:subscribe(View, client(Req)) of
                {ok, Poller} ->
                    hold_open(Code, Headers, Poller, Req);
                {error, too_many_streams_for_client} ->
                    refuse(429, Callback, Req);
                {error, _} ->
                    refuse(503, Callback, Req)
            end;
        error ->
            nova_basic_handler:handle_status({status, 404}, Callback, Req)
    end.

refuse(Status, Callback, Req) ->
    nova_basic_handler:handle_status({status, Status, #{~"retry-after" => ~"5"}}, Callback, Req).

-doc """
Who a stream is opened by, for the per-client limit.

When the host's `auth` callback returned `{true, AuthData}`, Nova has put
`AuthData` on the request and the client is that identity, wherever its
requests come from. Only a digest of it is kept. Two requests belong to the
same viewer when their `AuthData` is equal, so a callback should return
something stable for a viewer (a user id, a role and a name), not something
that differs from request to request.

Otherwise the client is the address the connection comes from, an IPv6
address counting by its /64. Behind a reverse proxy that is the proxy, so all
viewers share one limit unless the callback returns an identity.
""".
-spec client(cowboy_req:req()) -> nova_liveboard_poller:client().
client(#{auth_data := AuthData}) ->
    {identity, crypto:hash(sha256, term_to_binary(AuthData, [deterministic]))};
client(#{peer := {{A, B, C, D, _, _, _, _}, _Port}}) ->
    {peer, {A, B, C, D, 0, 0, 0, 0}};
client(#{peer := {Address, _Port}}) ->
    {peer, Address}.

-spec view(term(), [{binary(), binary() | true}]) -> {ok, nova_liveboard_poller:view()} | error.
view(~"processes", Qs) ->
    {ok, {processes, sort(Qs)}};
view(~"supervisors", Qs) ->
    {ok, {supervisors, app(Qs)}};
view(Name, _Qs) ->
    case ?PAGES of
        #{Name := Page} -> {ok, {Page, undefined}};
        _ -> error
    end.

-spec hold_open(cowboy:http_status(), cowboy:http_headers(), pid(), cowboy_req:req()) ->
    no_return().
hold_open(Code, Headers, Poller, Req0) ->
    Lifetime = nova_liveboard:stream_lifetime_ms(),
    Deadline = erlang:monotonic_time(millisecond) + Lifetime,
    Monitor = erlang:monitor(process, Poller),
    ok = cowboy_req:cast({set_options, #{idle_timeout => Lifetime + ?IDLE_MARGIN_MS}}, Req0),
    Req = cowboy_req:stream_reply(Code, Headers, Req0),
    hold(Req, Monitor, Deadline).

-spec hold(cowboy_req:req(), reference(), integer()) -> no_return().
hold(Req, Monitor, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 ->
            receive
                {nova_liveboard_frame, Frame} ->
                    ok = cowboy_req:stream_body(latest(Frame), nofin, Req),
                    hold(Req, Monitor, Deadline);
                {'DOWN', Monitor, process, _Pid, _Reason} ->
                    finish(Req);
                _Other ->
                    hold(Req, Monitor, Deadline)
            after Left ->
                finish(Req)
            end;
        _ ->
            finish(Req)
    end.

%% Frames that queued up behind a slow client are superseded by the newest.
latest(Frame) ->
    receive
        {nova_liveboard_frame, Newer} -> latest(Newer)
    after 0 ->
        Frame
    end.

%% Ends the response and the request process. Returning to Nova instead would
%% make it reply a second time.
-spec finish(cowboy_req:req()) -> no_return().
finish(Req) ->
    ok = cowboy_req:stream_body(~"", fin, Req),
    exit(normal).

headers() ->
    maps:from_list(datastar:sse_headers()).

sort(Qs) ->
    case proplists:get_value(~"sort", Qs) of
        ~"reductions" -> reductions;
        ~"message_queue_len" -> message_queue_len;
        _ -> memory
    end.

app(Qs) ->
    Names = nova_liveboard_page_controller:app_names(),
    case proplists:get_value(~"app", Qs) of
        undefined ->
            nova_liveboard_page_controller:default_app(Names);
        Bin ->
            case lists:search(fun(A) -> atom_to_binary(A) =:= Bin end, Names) of
                {value, A} -> A;
                false -> nova_liveboard_page_controller:default_app(Names)
            end
    end.
