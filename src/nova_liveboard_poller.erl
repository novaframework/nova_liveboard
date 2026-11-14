-module(nova_liveboard_poller).
-moduledoc """
Renders the live regions and fans the result out to the open streams.

A stream subscribes with the view it shows (`{Page, Option}`). Every
`refresh_ms` the poller renders each distinct view that has at least one
subscriber, once, and sends the frame to all of them, so the work done
inspecting the node depends on how many different views are open, not on how
many browsers are connected. The next tick is scheduled when a pass has
finished: a slow pass slows the refresh down instead of piling work up.

The Requests view is not polled. The poller is the tracer's only subscriber
and repaints the view shortly after the tracer reports a change, at most once
per `?REQUESTS_FLUSH_MS`, so a burst of requests on the node costs one render
however many streams are watching.

At most `max_streams` subscriptions exist at a time, and at most
`max_streams_per_client` of them belong to one client; `subscribe/2` refuses
the rest. A client is whoever the stream was opened by: the identity the
host's `auth` callback returned, or else the address the request came from
(see `nova_liveboard_sse:client/1`). A subscriber is dropped when its process
exits.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, subscribe/2, stream_count/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(PAGE, ~"#page").
-define(VITALS, ~"#vitals").
-define(REQUESTS, {requests, undefined}).
-define(METRICS, {metrics, undefined}).
-define(REQUESTS_FLUSH_MS, 200).

-type view() :: {Page :: atom(), Option :: atom()}.
-type client() :: {identity, Digest :: binary()} | {peer, inet:ip_address()}.
-type state() :: #{
    subscribers := #{pid() => view()},
    clients := #{pid() => client()},
    timer := reference() | undefined,
    flush := reference() | undefined,
    metrics := map() | undefined,
    failing := boolean()
}.

-export_type([view/0, client/0]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Subscribe the calling process to `View` on behalf of `Client`. It then
receives `{nova_liveboard_frame, Frame}` whenever the view is repainted, until
it exits. Returns the poller pid so the caller can monitor it.

Refused with `too_many_streams` when `max_streams` streams are open and with
`too_many_streams_for_client` when `Client` already has
`max_streams_per_client` of them. A process that subscribes again changes its
view; it takes no further slot and stays with the client it first named.
""".
-spec subscribe(view(), client()) ->
    {ok, pid()} | {error, too_many_streams | too_many_streams_for_client | unavailable}.
subscribe(View, Client) ->
    try gen_server:call(?MODULE, {subscribe, View, Client}) of
        {ok, Poller} when is_pid(Poller) -> {ok, Poller};
        {error, too_many_streams_for_client} -> {error, too_many_streams_for_client};
        _ -> {error, too_many_streams}
    catch
        exit:_ -> {error, unavailable}
    end.

-doc "Number of streams currently subscribed.".
-spec stream_count() -> non_neg_integer().
stream_count() ->
    case gen_server:call(?MODULE, stream_count) of
        Count when is_integer(Count), Count >= 0 -> Count
    end.

-spec init([]) -> {ok, state()}.
init([]) ->
    ok = follow_tracer(),
    {ok, #{
        subscribers => #{},
        clients => #{},
        timer => undefined,
        flush => undefined,
        metrics => undefined,
        failing => false
    }}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call({subscribe, Requested, Requester}, {Pid, _Tag}, State) ->
    #{subscribers := Subscribers, clients := Clients} = State,
    case {view(Requested), client(Requester)} of
        {{ok, View}, {ok, Client}} ->
            case room(Pid, Client, Clients) of
                ok ->
                    _ = is_map_key(Pid, Subscribers) orelse erlang:monitor(process, Pid),
                    Subscribed = State#{
                        subscribers := Subscribers#{Pid => View},
                        clients := Clients#{Pid => maps:get(Pid, Clients, Client)}
                    },
                    {reply, {ok, self()}, flush_soon(View, schedule(Subscribed))};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        _ ->
            {reply, {error, too_many_streams}, State}
    end;
handle_call(stream_count, _From, State = #{subscribers := Subscribers}) ->
    {reply, map_size(Subscribers), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(tick, State = #{subscribers := Subscribers, metrics := Previous}) ->
    Audiences = audiences(Subscribers),
    Metrics = metrics(is_map_key(?METRICS, Audiences), Previous),
    Failed = [
        View
     || View := Pids <- Audiences, View =/= ?REQUESTS, not broadcast(View, Metrics, Pids)
    ],
    {noreply, schedule(report(Failed, State#{timer := undefined, metrics := Metrics}))};
handle_info(flush_requests, State = #{subscribers := Subscribers}) ->
    Pids = [Pid || Pid := View <- Subscribers, View =:= ?REQUESTS],
    _ = broadcast(?REQUESTS, undefined, Pids),
    {noreply, State#{flush := undefined}};
handle_info({nova_liveboard_request, _Request}, State) ->
    {noreply, flush_soon(?REQUESTS, State)};
handle_info({nova_liveboard_trace_state, _TraceState}, State) ->
    {noreply, flush_soon(?REQUESTS, State)};
handle_info(nova_liveboard_requests_cleared, State) ->
    {noreply, flush_soon(?REQUESTS, State)};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) when is_pid(Pid) ->
    #{subscribers := Subscribers, clients := Clients} = State,
    {noreply, State#{
        subscribers := maps:remove(Pid, Subscribers), clients := maps:remove(Pid, Clients)
    }};
handle_info(_Info, State) ->
    {noreply, State}.

%% The supervisor starts the tracer first and restarts the poller with it, so
%% the subscription only fails when the poller runs on its own.
-spec follow_tracer() -> ok.
follow_tracer() ->
    try
        nova_liveboard_tracer:subscribe()
    catch
        exit:_ -> ok
    end.

-spec view(term()) -> {ok, view()} | error.
view({Page, Option}) when is_atom(Page), is_atom(Option) -> {ok, {Page, Option}};
view(_) -> error.

-spec client(term()) -> {ok, client()} | error.
client({identity, Digest}) when is_binary(Digest) ->
    {ok, {identity, Digest}};
client({peer, Address}) when is_tuple(Address) ->
    case inet:is_ip_address(Address) of
        true -> {ok, {peer, Address}};
        false -> error
    end;
client(_) ->
    error.

%% Whether `Pid` may hold a stream for `Client`. A process that is already
%% subscribed keeps the slot it has.
-spec room(pid(), client(), #{pid() => client()}) ->
    ok | {error, too_many_streams | too_many_streams_for_client}.
room(Pid, _Client, Clients) when is_map_key(Pid, Clients) ->
    ok;
room(_Pid, Client, Clients) ->
    Held = length([Holder || _ := Holder <- Clients, Holder =:= Client]),
    case
        {
            map_size(Clients) < nova_liveboard:max_streams(),
            Held < nova_liveboard:max_streams_per_client()
        }
    of
        {true, true} -> ok;
        {true, false} -> {error, too_many_streams_for_client};
        {false, _} -> {error, too_many_streams}
    end.

-spec audiences(#{pid() => view()}) -> #{view() => [pid()]}.
audiences(Subscribers) ->
    maps:groups_from_list(
        fun({_Pid, View}) -> View end, fun({Pid, _View}) -> Pid end, maps:to_list(Subscribers)
    ).

%% The metrics view accumulates samples between ticks. They are kept only
%% while someone is watching.
-spec metrics(boolean(), map() | undefined) -> map() | undefined.
metrics(true, Previous) ->
    try
        nova_liveboard_data:collect_metrics(Previous)
    catch
        _:_ -> undefined
    end;
metrics(false, _Previous) ->
    undefined.

%% Renders `View` once and sends the frame to every stream showing it.
-spec broadcast(view(), map() | undefined, [pid()]) -> boolean().
broadcast(_View, _Metrics, []) ->
    true;
broadcast(View, Metrics, Pids) ->
    case frame(View, Metrics) of
        {ok, Frame} ->
            _ = [Pid ! {nova_liveboard_frame, Frame} || Pid <- Pids],
            true;
        error ->
            false
    end.

-spec schedule(state()) -> state().
schedule(State = #{subscribers := Subscribers, timer := undefined}) when
    map_size(Subscribers) > 0
->
    State#{timer := erlang:send_after(nova_liveboard:refresh_ms(), self(), tick)};
schedule(State) ->
    State.

-spec flush_soon(view(), state()) -> state().
flush_soon(?REQUESTS, State = #{flush := undefined}) ->
    State#{flush := erlang:send_after(?REQUESTS_FLUSH_MS, self(), flush_requests)};
flush_soon(_View, State) ->
    State.

-spec frame(view(), map() | undefined) -> {ok, binary()} | error.
frame(View, Metrics) ->
    try
        {Selector, Inner} = inner(View, Metrics),
        {ok,
            iolist_to_binary(
                datastar:patch_elements(Inner, #{selector => Selector, mode => inner})
            )}
    catch
        _:_ -> error
    end.

-spec inner(view(), map() | undefined) -> {binary(), iodata()}.
inner({vitals, _Option}, _Metrics) ->
    {?VITALS, nova_liveboard_html:vitals_html(nova_liveboard_data:system_info())};
inner(?METRICS, Metrics) when is_map(Metrics) ->
    {?PAGE, nova_liveboard_html:metrics_html(Metrics)};
inner({Page, Option}, _Metrics) when Page =/= metrics ->
    {?PAGE, nova_liveboard_page_controller:page_inner(Page, Option)}.

%% Logged when rendering starts failing, not on every tick while it does.
-spec report([view()], state()) -> state().
report([], State) ->
    State#{failing := false};
report(_Failed, State = #{failing := true}) ->
    State;
report(Failed, State) ->
    ?LOG_WARNING(#{
        msg => ~"nova_liveboard_render_failed",
        pages => lists:usort([Page || {Page, _Option} <- Failed])
    }),
    State#{failing := true}.
