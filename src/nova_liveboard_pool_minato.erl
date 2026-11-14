-module(nova_liveboard_pool_minato).
-moduledoc """
Figures of a `kura_pool_minato` pool, the pool of `kura_postgres`.

`kura_pool_minato:start_pool/2` starts a minato pool under the repo's pool
name, and `minato:stats/1` reports what that pool holds and what it has done
since it started. That is the only function of minato called here.
""".
-behaviour(nova_liveboard_pool).

-export([backend/0, figures/1]).

-define(COUNTERS, [
    {checkouts, ~"checkouts"},
    {waits, ~"waits"},
    {timeouts, ~"timeouts"},
    {disconnects, ~"disconnects"},
    {retired, ~"retired"}
]).

-spec backend() -> binary().
backend() ->
    ~"postgres (minato)".

-spec figures(atom()) -> nova_liveboard_pool:reading().
figures(Pool) ->
    case nova_liveboard_optional:call(minato, stats, [Pool]) of
        {ok, Stats} -> shown(Stats);
        absent -> {not_available, ~"minato is not on this node"};
        missing -> {not_available, ~"minato:stats/1 is not exported by the minato on this node"};
        {raised, exit, {noproc, _}} -> not_started;
        {raised, _, _} -> {not_available, ~"minato:stats/1 failed"}
    end.

-spec shown(term()) -> nova_liveboard_pool:reading().
shown(#{size := Size, idle := Idle, borrowed := Borrowed, waiting := Waiting} = Stats) when
    is_integer(Size),
    Size >= 0,
    is_integer(Idle),
    Idle >= 0,
    is_integer(Borrowed),
    Borrowed >= 0,
    is_integer(Waiting),
    Waiting >= 0
->
    {ok, #{
        size => Size,
        in_use => Borrowed,
        idle => Idle,
        waiting => Waiting,
        counters => [
            {Label, Count}
         || {Key, Label} <- ?COUNTERS,
            {ok, Count} <- [maps:find(Key, Stats)],
            is_integer(Count),
            Count >= 0
        ]
    }};
shown(_) ->
    {not_available, ~"minato:stats/1 answered in a shape the liveboard does not know"}.
