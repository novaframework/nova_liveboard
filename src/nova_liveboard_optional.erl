-module(nova_liveboard_optional).
-moduledoc """
Calls into libraries the liveboard does not depend on.

Kura and minato are looked for in the running node and called only when they
are there. A call is an exported function applied by name: nothing here reads
the state of another library's processes.

`call/3` runs in the calling process. `start/3` and `answer/2` run the same
call in a process of its own, so a call that blocks costs the caller no more
than the time it allowed, and is abandoned after that.
""".

-export([call/3, start/3, answer/2, deadline/1]).

-doc """
What a call came to: `absent` when the module is not on the node, `missing`
when the module there does not export the function, `{raised, Class, Reason}`
when the call failed.
""".
-type result() :: {ok, term()} | absent | missing | {raised, error | exit | throw, term()}.

-opaque request() :: {pid(), reference()}.

-export_type([result/0, request/0]).

-doc "Applies `Module:Function` to `Arguments` in the calling process.".
-spec call(module(), atom(), [term()]) -> result().
call(Module, Function, Arguments) ->
    case code:ensure_loaded(Module) of
        {module, _} ->
            case erlang:function_exported(Module, Function, length(Arguments)) of
                true -> applied(Module, Function, Arguments);
                false -> missing
            end;
        {error, _} ->
            absent
    end.

-doc "Starts `call/3` in a process of its own. `answer/2` collects it.".
-spec start(module(), atom(), [term()]) -> request().
start(Module, Function, Arguments) ->
    spawn_monitor(fun() -> exit({?MODULE, call(Module, Function, Arguments)}) end).

-doc """
What a call started with `start/3` came to, or `timeout` when it has not
answered by `Deadline`, a time from `deadline/1`. A call that timed out is
killed.
""".
-spec answer(request(), integer()) -> result() | timeout.
answer({Worker, Monitor}, Deadline) ->
    receive
        {'DOWN', Monitor, process, Worker, {?MODULE, Result}} -> result(Result);
        {'DOWN', Monitor, process, Worker, Reason} -> {raised, exit, Reason}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        true = exit(Worker, kill),
        true = erlang:demonitor(Monitor, [flush]),
        timeout
    end.

-doc "The time `Milliseconds` from now, for `answer/2`.".
-spec deadline(non_neg_integer()) -> integer().
deadline(Milliseconds) ->
    erlang:monotonic_time(millisecond) + Milliseconds.

-spec applied(module(), atom(), [term()]) -> result().
applied(Module, Function, Arguments) ->
    try
        {ok, erlang:apply(Module, Function, Arguments)}
    catch
        Class:Reason -> {raised, Class, Reason}
    end.

-spec result(term()) -> result().
result({ok, Answer}) ->
    {ok, Answer};
result(absent) ->
    absent;
result(missing) ->
    missing;
result({raised, Class, Reason}) when Class =:= error; Class =:= exit; Class =:= throw ->
    {raised, Class, Reason};
result(Other) ->
    {raised, exit, Other}.
