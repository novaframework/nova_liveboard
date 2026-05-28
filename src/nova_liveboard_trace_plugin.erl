-module(nova_liveboard_trace_plugin).
-moduledoc """
Nova plugin that feeds the liveboard's request tracer.

Register it as a global plugin in your Nova config to capture every request
handled by the node:

    {nova, [
      {plugins, [
        {pre_request,  nova_liveboard_trace_plugin, #{}},
        {post_request, nova_liveboard_trace_plugin, #{}}
      ]}
    ]}.

`pre_request/4` stamps the request with an id, start time, reductions baseline
and the resolved handler MFA (from `Env#{callback}`), and - when deep trace is
armed - turns on scoped process tracing of the handling process.
`post_request/4` computes duration / reductions / peak memory / status and
hands the summary to `nova_liveboard_tracer`. The whole chain runs in one
process, so the marker stashed in `Req` survives from pre to post.

The dashboard's own routes are skipped so it never traces itself (its SSE
streams never return, and would otherwise never finalise).
""".

-behaviour(nova_plugin).

-export([init/0, pre_request/4, post_request/4, plugin_info/0]).

-define(MARK, '$nova_liveboard_trace').

-spec init() -> {ok, undefined}.
init() ->
    {ok, undefined}.

pre_request(Req, Env, _Opts, State) ->
    case skip(Req) of
        true ->
            {ok, Req, State};
        false ->
            ReqId = new_id(),
            Traced = arm(ReqId),
            Mark = #{
                id => ReqId,
                t0 => erlang:monotonic_time(microsecond),
                reds0 => reductions(),
                method => cowboy_req:method(Req),
                path => cowboy_req:path(Req),
                handler => handler_mfa(Env),
                traced => Traced
            },
            {ok, Req#{?MARK => Mark}, State}
    end.

post_request(Req, _Env, _Opts, State) ->
    case maps:get(?MARK, Req, undefined) of
        undefined ->
            {ok, Req, State};
        Mark ->
            finalize(Req, Mark),
            {ok, Req, State}
    end.

plugin_info() ->
    #{
        title => ~"Nova Liveboard request tracer",
        version => ~"1.0.0",
        url => ~"https://github.com/novaframework/nova_liveboard",
        authors => [~"nova_liveboard"],
        description =>
            ~"Captures per-request timing, reductions and (in deep mode) the tree of processes spawned while handling each request.",
        options => []
    }.

%% ---------------------------------------------------------------------------
%% internal
%% ---------------------------------------------------------------------------

finalize(Req, Mark) ->
    #{id := ReqId, t0 := T0, reds0 := Reds0, traced := Traced} = Mark,
    Traced andalso untrace_self(),
    Summary = #{
        id => ReqId,
        method => maps:get(method, Mark),
        path => maps:get(path, Mark),
        handler => maps:get(handler, Mark),
        status => maps:get(resp_status_code, Req, undefined),
        duration_us => erlang:monotonic_time(microsecond) - T0,
        reductions => max(0, reductions() - Reds0),
        mem => mem(),
        ts => erlang:system_time(millisecond)
    },
    nova_liveboard_tracer:finalize(ReqId, Summary).

untrace_self() ->
    try
        erlang:trace(self(), false, [procs, set_on_spawn])
    catch
        _:_ -> 0
    end.

%% Arm scoped tracing of the current (request-handling) process when the
%% tracer says deep trace is on. set_on_spawn makes any process this one
%% spawns inherit the trace, so the whole spawned subtree is captured.
arm(ReqId) ->
    case whereis(nova_liveboard_tracer) of
        undefined ->
            false;
        Tracer ->
            case nova_liveboard_tracer:maybe_arm(ReqId, self()) of
                trace ->
                    erlang:trace(self(), true, [procs, set_on_spawn, {tracer, Tracer}]),
                    true;
                no_trace ->
                    false
            end
    end.

skip(Req) ->
    whereis(nova_liveboard_tracer) =:= undefined orelse
        own_path(cowboy_req:path(Req)).

own_path(Path) ->
    Prefix = nova_liveboard:prefix(),
    case binary:match(Path, Prefix) of
        {0, _} -> true;
        _ -> false
    end.

handler_mfa(#{callback := Fun}) when is_function(Fun) ->
    Info = erlang:fun_info(Fun),
    M = proplists:get_value(module, Info, unknown),
    F = proplists:get_value(name, Info, unknown),
    A = proplists:get_value(arity, Info, 0),
    iolist_to_binary(io_lib:format("~s:~s/~b", [M, F, A]));
handler_mfa(#{callback := {M, F}}) ->
    iolist_to_binary(io_lib:format("~s:~s", [M, F]));
handler_mfa(_) ->
    ~"unknown".

reductions() ->
    {reductions, R} = erlang:process_info(self(), reductions),
    R.

mem() ->
    case erlang:process_info(self(), memory) of
        {memory, M} -> M;
        undefined -> 0
    end.

new_id() ->
    string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(6))).
