-module(nova_liveboard_tracer).
-moduledoc """
Request store and deep-trace collector for the liveboard.

Two jobs in one `gen_server`:

1. **Store** - a capped, newest-first ring of recently completed requests
   (`nova_liveboard:request_buffer/0` deep). `nova_liveboard_trace_plugin`
   calls `finalize/2` from each request's `post_request` hook; SSE feeds
   `subscribe/0` to it for live updates.

2. **Trace collector** - when deep trace is armed (`start_trace/1`), the next
   N requests have their handling process traced with
   `erlang:trace(self(), true, [procs, set_on_spawn, {tracer, Pid}])` (the
   plugin enables it; this server is the `Pid`). It receives
   `{trace, Parent, spawn, Child, MFA}` messages, attributes each spawned
   process to the owning request by walking the parent chain, and attaches the
   resulting spawned-process tree to the request record on `finalize/2`.

The dashboard works without any of this; only the Requests page needs the
plugin registered.
""".

-behaviour(gen_server).

-export([
    start_link/0,
    maybe_arm/2,
    finalize/2,
    recent/0,
    get/1,
    clear/0,
    subscribe/0,
    start_trace/1,
    stop_trace/0,
    trace_state/0,
    active/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

-record(state, {
    requests = [] :: [map()],
    cap = 200 :: pos_integer(),
    armed = 0 :: non_neg_integer(),
    active = false :: boolean(),
    subs = #{} :: #{reference() => pid()},
    %% in-flight deep traces, keyed by request id
    traces = #{} :: #{binary() => trace_acc()},
    %% any currently-traced pid -> the request id that owns it
    pid2req = #{} :: #{pid() => binary()}
}).

-type trace_acc() :: #{nodes := [map()], depths := #{pid() => non_neg_integer()}}.

%% ---------------------------------------------------------------------------
%% api
%% ---------------------------------------------------------------------------

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc """
Ask whether the request `ReqId` handled by `RootPid` should be deep-traced.

Returns `trace` (and registers the root pid) when deep trace is armed, else
`no_trace`. The caller (the request process) is responsible for calling
`erlang:trace/3` on itself when `trace` is returned.
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

-doc "Whether any request has been captured (a proxy for 'plugin is wired up').".
-spec active() -> boolean().
active() -> gen_server:call(?SERVER, active).

%% ---------------------------------------------------------------------------
%% gen_server
%% ---------------------------------------------------------------------------

init([]) ->
    {ok, #state{cap = nova_liveboard:request_buffer()}}.

handle_call({maybe_arm, ReqId, RootPid}, _From, #state{armed = N} = S) when N > 0 ->
    Acc = #{nodes => [], depths => #{RootPid => 0}},
    S1 = S#state{
        armed = N - 1,
        active = true,
        traces = (S#state.traces)#{ReqId => Acc},
        pid2req = (S#state.pid2req)#{RootPid => ReqId}
    },
    {reply, trace, notify_trace_state(S1)};
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

handle_info({trace, Parent, spawn, Child, MFA}, S) ->
    {noreply, record_spawn(Parent, Child, MFA, S)};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, S) ->
    {noreply, S#state{subs = maps:remove(Ref, S#state.subs)}};
handle_info(_Msg, S) ->
    {noreply, S}.

%% ---------------------------------------------------------------------------
%% trace bookkeeping
%% ---------------------------------------------------------------------------

record_spawn(Parent, Child, MFA, S) ->
    case maps:find(Parent, S#state.pid2req) of
        {ok, ReqId} ->
            Acc = maps:get(ReqId, S#state.traces),
            Depths = maps:get(depths, Acc),
            Depth = maps:get(Parent, Depths, 0) + 1,
            Node = #{
                pid => pid_bin(Child),
                mfa => format_mfa(MFA),
                parent => pid_bin(Parent),
                depth => Depth
            },
            Acc1 = Acc#{
                nodes => [Node | maps:get(nodes, Acc)],
                depths => Depths#{Child => Depth}
            },
            S#state{
                traces = (S#state.traces)#{ReqId => Acc1},
                pid2req = (S#state.pid2req)#{Child => ReqId}
            };
        error ->
            S
    end.

take_trace(ReqId, S) ->
    case maps:take(ReqId, S#state.traces) of
        {Acc, Traces1} ->
            Pids = maps:keys(maps:get(depths, Acc)),
            untrace(Pids),
            Pid2Req1 = maps:without(Pids, S#state.pid2req),
            Tree = lists:reverse(maps:get(nodes, Acc)),
            {Tree, S#state{traces = Traces1, pid2req = Pid2Req1}};
        error ->
            {[], S}
    end.

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
    iolist_to_binary(io_lib:format("~p", [Other])).
