-module(nova_liveboard_sse).
-moduledoc """
The liveboard's live transport: one long-lived SSE stream per page region.

`stream/1` is a normal Nova controller returning `{stream, Code, Headers,
Source}`. That tuple is picked up by a return-handler we register
(`handle_stream/3`), which `stream_reply`s the SSE headers and then **holds the
connection**, pushing `datastar:patch_elements/2` frames and never returning -
so Nova's buffered `render_response` (which would reply again and crash) never
runs. On client disconnect the next `stream_body` fails and the request process
exits, dropping any tracer subscription. See novaframework/nova#387.

Two stream shapes:

- **polled** (vitals/overview/processes/ets/applications/ports/supervisors/
  metrics): a `receive ... after RefreshMs` timer repaints the region. The
  metrics stream threads the `nova_liveboard_data:collect_metrics/1`
  accumulator through its loop so sparklines and scheduler deltas build up.
- **event-driven** (requests): subscribes to `nova_liveboard_tracer` and
  prepends each request as it completes; no polling.

The handler is registered as an explicit `fun/3` because current Nova invokes
return-handlers with 3 args, while its `{Mod, Fun}` form wraps to arity 4.
""".

-export([register/0, stream/1, handle_stream/3]).

-define(PAGE, ~"#page").
-define(VITALS, ~"#vitals").

-spec register() -> ok | {error, atom()}.
register() ->
    nova_handlers:register_handler(stream, fun ?MODULE:handle_stream/3).

%% Nova controller: GET <prefix>/sse/:page
stream(Req) ->
    Page = maps:get(~"page", maps:get(bindings, Req, #{}), ~"overview"),
    Qs = cowboy_req:parse_qs(Req),
    {stream, 200, headers(), {Page, Qs}}.

handle_stream({stream, Code, Headers, Source}, _Callback, Req0) ->
    Req = cowboy_req:stream_reply(Code, Headers, Req0),
    serve(Source, Req).

%% ---------------------------------------------------------------------------
%% per-page streams
%% ---------------------------------------------------------------------------

serve({~"vitals", _Qs}, Req) ->
    loop_poll(vitals, undefined, Req);
serve({~"metrics", _Qs}, Req) ->
    State = nova_liveboard_data:collect_metrics(undefined),
    case send(Req, page_inner(nova_liveboard_html:metrics_html(State))) of
        ok -> loop_metrics(State, Req);
        stop -> ok
    end;
serve({~"requests", _Qs}, Req) ->
    ok = nova_liveboard_tracer:subscribe(),
    send(Req, page_frame(requests, undefined)),
    loop_requests(Req);
serve({~"processes", Qs}, Req) ->
    loop_poll(processes, sort(Qs), Req);
serve({~"supervisors", Qs}, Req) ->
    loop_poll(supervisors, app(Qs), Req);
serve({Page, _Qs}, Req) ->
    loop_poll(nova_liveboard_page_controller:page_atom(Page), undefined, Req).

loop_poll(Page, Opt, Req) ->
    receive
        _ -> loop_poll(Page, Opt, Req)
    after refresh() ->
        case send(Req, region_frame(Page, Opt)) of
            ok -> loop_poll(Page, Opt, Req);
            stop -> ok
        end
    end.

%% Metrics needs a stateful accumulator; carry it through the loop.
loop_metrics(State, Req) ->
    receive
    after refresh() ->
        State1 = nova_liveboard_data:collect_metrics(State),
        case send(Req, page_inner(nova_liveboard_html:metrics_html(State1))) of
            ok -> loop_metrics(State1, Req);
            stop -> ok
        end
    end.

loop_requests(Req) ->
    receive
        {nova_liveboard_request, R} ->
            ok = send(Req, prepend_request(R)),
            ok = send(Req, toolbar_frame()),
            loop_requests(Req);
        {nova_liveboard_trace_state, _TS} ->
            ok = send(Req, toolbar_frame()),
            loop_requests(Req);
        nova_liveboard_requests_cleared ->
            ok = send(Req, page_frame(requests, undefined)),
            loop_requests(Req);
        _ ->
            loop_requests(Req)
    end.

%% ---------------------------------------------------------------------------
%% frames
%% ---------------------------------------------------------------------------

region_frame(vitals, _) ->
    datastar:patch_elements(
        nova_liveboard_html:vitals_html(nova_liveboard_data:system_info()),
        #{selector => ?VITALS, mode => inner}
    );
region_frame(Page, Opt) ->
    page_frame(Page, Opt).

page_frame(Page, Opt) ->
    page_inner(nova_liveboard_page_controller:page_inner(Page, Opt)).

page_inner(Html) ->
    datastar:patch_elements(Html, #{selector => ?PAGE, mode => inner}).

prepend_request(R) ->
    datastar:patch_elements(
        nova_liveboard_html:request_row(R),
        #{selector => ~"#req-feed", mode => prepend}
    ).

toolbar_frame() ->
    datastar:patch_elements(
        nova_liveboard_html:requests_toolbar_html(nova_liveboard_tracer:trace_state()),
        #{selector => ~"#req-toolbar", mode => inner}
    ).

%% ---------------------------------------------------------------------------
%% transport + query parsing
%% ---------------------------------------------------------------------------

send(Req, Frame) ->
    try
        ok = cowboy_req:stream_body(Frame, nofin, Req),
        ok
    catch
        _:_ -> stop
    end.

headers() ->
    maps:from_list(datastar:sse_headers()).

refresh() ->
    nova_liveboard:refresh_ms().

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
