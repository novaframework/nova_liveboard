-module(nova_liveboard_tracer).
-moduledoc """
Request store and deep-trace collector for the liveboard.

Two jobs in one `gen_server`:

1. **Store** - a capped, newest-first ring of recently completed requests
   (`nova_liveboard:request_buffer/0` deep). `nova_liveboard_trace_plugin`
   calls `finalize/2` from each request's `post_request` hook;
   `nova_liveboard_poller` `subscribe/0`s to it for live updates.

2. **Trace collector** - when deep trace is armed (`start_trace/1`), the next
   N requests have their handling process traced with
   `erlang:trace(self(), true, [procs, set_on_spawn, {tracer, Pid}])` (the
   plugin enables it; this server is the `Pid`). It receives
   `{trace, Parent, spawn, Child, MFA}` messages, attributes each spawned
   process to the owning request by walking the parent chain, and attaches the
   resulting spawned-process tree to the request record on `finalize/2`.

A deep trace normally ends in `finalize/2`. A request that never gets there
(its handler crashed, it was upgraded to a websocket, the client went away)
would otherwise keep its bookkeeping forever, so in-flight traces are bounded
three ways:

- the request process is monitored and its trace is dropped when it exits;
- a trace older than 60 seconds is dropped by a periodic sweep, and the
  request is then listed without a spawned tree;
- at most 64 traces are in flight and at most 5000 processes are followed
  over all of them. Beyond that a request is not traced and a spawned process
  is not followed.

A dropped trace has tracing turned off for every process it followed.

The dashboard works without any of this; only the Requests page needs the
plugin registered.
""".

-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    maybe_arm/2,
    finalize/2,
    recent/0,
    get/1,
    clear/0,
    subscribe/0,
    start_trace/1,
    stop_trace/0,
    trace_state/0,
    in_flight/0,
    active/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(LIMITS, #{max_traces => 64, max_pids => 5000, max_age_ms => 60000, sweep_ms => 5000}).

-record(state, {
    requests = [] :: [map()],
    cap = 200 :: pos_integer(),
    armed = 0 :: non_neg_integer(),
    active = false :: boolean(),
    subs = #{} :: #{reference() => pid()},
    %% in-flight deep traces, keyed by request id
    traces = #{} :: #{binary() => trace_acc()},
    %% any currently-traced pid -> the request id that owns it
    pid2req = #{} :: #{pid() => binary()},
    %% the monitor on each traced request process -> its request id
    monitors = #{} :: #{reference() => binary()},
    limits = ?LIMITS :: limits(),
    sweep = undefined :: reference() | undefined
}).

-type trace_acc() :: #{
    monitor := reference(),
    started := integer(),
    nodes := [map()],
    depths := #{pid() => non_neg_integer()}
}.
-type limits() :: #{
    max_traces := pos_integer(),
    max_pids := pos_integer(),
    max_age_ms := pos_integer(),
    sweep_ms := pos_integer()
}.

-export_type([limits/0]).

%% ---------------------------------------------------------------------------
%% api
%% ---------------------------------------------------------------------------

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-doc """
As `start_link/0`, with some of the bounds on in-flight deep traces replaced:
`max_traces` (64), `max_pids` (5000), `max_age_ms` (60000) and `sweep_ms`
(5000).
""".
-spec start_link(#{atom() => pos_integer()}) -> gen_server:start_ret().
start_link(Limits) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Limits, []).

-doc """
Ask whether the request `ReqId` handled by `RootPid` should be deep-traced.

Returns `trace` (and registers and monitors the root pid) when deep trace is
armed and fewer than `max_traces` traces are in flight, else `no_trace`. The
caller (the request process) is responsible for calling `erlang:trace/3` on
itself when `trace` is returned.
""".
-spec maybe_arm(binary(), pid()) -> trace | no_trace.
maybe_arm(ReqId, RootPid) ->
    gen_server:call(?SERVER, {maybe_arm, ReqId, RootPid}).

-doc "Record a completed request; attaches the spawned tree if it was traced.".
-spec finalize(binary(), map()) -> ok.
finalize(ReqId, Summary) ->
    gen_server:cast(?SERVER, {finalize, ReqId, Summary}).

-spec recent() -> [map()].
recent() -> gen_server:call(?SERVER, recent).

-spec get(binary()) -> map() | undefined.
get(ReqId) -> gen_server:call(?SERVER, {get, ReqId}).

-spec clear() -> ok.
clear() -> gen_server:cast(?SERVER, clear).

-doc "Register the caller for live request + trace-state notifications.".
-spec subscribe() -> ok.
subscribe() -> gen_server:call(?SERVER, {subscribe, self()}).

-spec start_trace(pos_integer()) -> ok.
start_trace(N) -> gen_server:cast(?SERVER, {start_trace, N}).

-spec stop_trace() -> ok.
stop_trace() -> gen_server:cast(?SERVER, stop_trace).

-spec trace_state() -> map().
trace_state() -> gen_server:call(?SERVER, trace_state).

-doc "How many deep traces are in flight and how many processes they follow.".
-spec in_flight() -> #{traces := non_neg_integer(), pids := non_neg_integer()}.
in_flight() ->
    case gen_server:call(?SERVER, in_flight) of
        #{traces := Traces, pids := Pids} when
            is_integer(Traces), Traces >= 0, is_integer(Pids), Pids >= 0
        ->
            #{traces => Traces, pids => Pids}
    end.

-doc "Whether any request has been captured (a proxy for 'plugin is wired up').".
-spec active() -> boolean().
active() -> gen_server:call(?SERVER, active).

%% ---------------------------------------------------------------------------
%% gen_server
%% ---------------------------------------------------------------------------

init(Limits) when is_map(Limits) ->
    {ok, #state{cap = nova_liveboard:request_buffer(), limits = limits(Limits)}}.

handle_call({maybe_arm, ReqId, RootPid}, _From, #state{armed = N} = S) when
    N > 0,
    is_binary(ReqId),
    is_pid(RootPid),
    map_size(S#state.traces) < map_get(max_traces, S#state.limits)
->
    Monitor = erlang:monitor(process, RootPid),
    Acc = #{
        monitor => Monitor,
        started => erlang:monotonic_time(millisecond),
        nodes => [],
        depths => #{RootPid => 0}
    },
    S1 = S#state{
        armed = N - 1,
        active = true,
        traces = (S#state.traces)#{ReqId => Acc},
        pid2req = (S#state.pid2req)#{RootPid => ReqId},
        monitors = (S#state.monitors)#{Monitor => ReqId}
    },
    {reply, trace, notify_trace_state(schedule_sweep(S1))};
handle_call({maybe_arm, _ReqId, _RootPid}, _From, S) ->
    {reply, no_trace, S#state{active = true}};
handle_call(recent, _From, S) ->
    {reply, S#state.requests, S};
handle_call({get, ReqId}, _From, S) ->
    Found =
        case lists:search(fun(R) -> maps:get(id, R) =:= ReqId end, S#state.requests) of
            {value, R} -> R;
            false -> undefined
        end,
    {reply, Found, S};
handle_call({subscribe, Pid}, _From, S) ->
    Ref = erlang:monitor(process, Pid),
    {reply, ok, S#state{subs = (S#state.subs)#{Ref => Pid}}};
handle_call(trace_state, _From, S) ->
    {reply, trace_state_map(S), S};
handle_call(in_flight, _From, S) ->
    {reply, #{traces => map_size(S#state.traces), pids => map_size(S#state.pid2req)}, S};
handle_call(active, _From, S) ->
    {reply, S#state.active, S};
handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast({finalize, ReqId, Summary}, S) ->
    {Tree, S1} = take_trace(ReqId, S),
    Record = Summary#{spawned => length(Tree), spawned_tree => Tree},
    Reqs = lists:sublist([Record | S1#state.requests], S1#state.cap),
    S2 = S1#state{requests = Reqs, active = true},
    notify(S2, {nova_liveboard_request, Record}),
    {noreply, S2};
handle_cast(clear, S) ->
    notify(S, nova_liveboard_requests_cleared),
    {noreply, S#state{requests = []}};
handle_cast({start_trace, N}, S) ->
    {noreply, notify_trace_state(S#state{armed = N})};
handle_cast(stop_trace, S) ->
    {noreply, notify_trace_state(S#state{armed = 0})};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({trace, Parent, spawn, Child, MFA}, S) when is_pid(Parent), is_pid(Child) ->
    {noreply, record_spawn(Parent, Child, MFA, S)};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, S) ->
    case S#state.monitors of
        #{Ref := ReqId} -> {noreply, drop_traces([ReqId], S)};
        #{} -> {noreply, S#state{subs = maps:remove(Ref, S#state.subs)}}
    end;
handle_info(sweep, S) ->
    Oldest = erlang:monotonic_time(millisecond) - map_get(max_age_ms, S#state.limits),
    Expired = [ReqId || ReqId := #{started := Started} <- S#state.traces, Started =< Oldest],
    {noreply, schedule_sweep(drop_traces(Expired, S#state{sweep = undefined}))};
handle_info(_Msg, S) ->
    {noreply, S}.

%% ---------------------------------------------------------------------------
%% trace bookkeeping
%% ---------------------------------------------------------------------------

record_spawn(Parent, Child, MFA, S) ->
    case S#state.pid2req of
        #{Parent := ReqId} when map_size(S#state.pid2req) < map_get(max_pids, S#state.limits) ->
            #{nodes := Nodes, depths := Depths} = Acc = maps:get(ReqId, S#state.traces),
            Depth = maps:get(Parent, Depths, 0) + 1,
            Node = #{
                pid => pid_bin(Child),
                mfa => format_mfa(MFA),
                parent => pid_bin(Parent),
                depth => Depth
            },
            Acc1 = Acc#{nodes := [Node | Nodes], depths := Depths#{Child => Depth}},
            S#state{
                traces = (S#state.traces)#{ReqId => Acc1},
                pid2req = (S#state.pid2req)#{Child => ReqId}
            };
        #{Parent := _ReqId} ->
            untrace([Child]),
            S;
        #{} ->
            S
    end.

take_trace(ReqId, S) ->
    case S#state.traces of
        #{ReqId := #{nodes := Nodes}} -> {lists:reverse(Nodes), drop_traces([ReqId], S)};
        #{} -> {[], S}
    end.

%% Forgets the traces of `ReqIds` and stops tracing every process they
%% followed.
-spec drop_traces([binary()], #state{}) -> #state{}.
drop_traces([], S) ->
    S;
drop_traces([ReqId | Rest], S) ->
    case maps:take(ReqId, S#state.traces) of
        {#{monitor := Monitor, depths := Depths}, Traces} ->
            true = erlang:demonitor(Monitor, [flush]),
            untrace(maps:keys(Depths)),
            drop_traces(Rest, S#state{
                traces = Traces,
                pid2req = #{Pid => Owner || Pid := Owner <- S#state.pid2req, Owner =/= ReqId},
                monitors = maps:remove(Monitor, S#state.monitors)
            });
        error ->
            drop_traces(Rest, S)
    end.

-spec untrace([pid()]) -> ok.
untrace(Pids) ->
    lists:foreach(
        fun(Pid) ->
            try
                erlang:trace(Pid, false, [procs, set_on_spawn])
            catch
                _:_ -> 0
            end
        end,
        Pids
    ).

-spec schedule_sweep(#state{}) -> #state{}.
schedule_sweep(#state{sweep = undefined, traces = Traces, limits = #{sweep_ms := Every}} = S) when
    map_size(Traces) > 0
->
    S#state{sweep = erlang:send_after(Every, self(), sweep)};
schedule_sweep(S) ->
    S.

-spec limits(#{atom() => term()}) -> limits().
limits(Given) ->
    #{
        max_traces => limit(max_traces, Given),
        max_pids => limit(max_pids, Given),
        max_age_ms => limit(max_age_ms, Given),
        sweep_ms => limit(sweep_ms, Given)
    }.

-spec limit(max_traces | max_pids | max_age_ms | sweep_ms, #{atom() => term()}) -> pos_integer().
limit(Key, Given) ->
    case Given of
        #{Key := Value} when is_integer(Value), Value > 0 -> Value;
        #{} -> map_get(Key, ?LIMITS)
    end.

%% ---------------------------------------------------------------------------
%% notifications
%% ---------------------------------------------------------------------------

notify(#state{subs = Subs}, Msg) ->
    maps:foreach(fun(_Ref, Pid) -> Pid ! Msg end, Subs).

notify_trace_state(S) ->
    notify(S, {nova_liveboard_trace_state, trace_state_map(S)}),
    S.

trace_state_map(#state{armed = N}) ->
    #{armed => N > 0, remaining => N}.

%% ---------------------------------------------------------------------------
%% helpers
%% ---------------------------------------------------------------------------

pid_bin(Pid) -> list_to_binary(pid_to_list(Pid)).

format_mfa({M, F, Args}) when is_list(Args) ->
    iolist_to_binary(io_lib:format("~s:~s/~b", [M, F, length(Args)]));
format_mfa({M, F, A}) when is_integer(A) ->
    iolist_to_binary(io_lib:format("~s:~s/~b", [M, F, A]));
format_mfa(Other) ->
    unicode:characters_to_binary(io_lib:format("~0tp", [Other], [{chars_limit, 200}])).
