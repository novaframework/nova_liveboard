-module(nova_liveboard_fake_minato).
-moduledoc """
Stands in for `minato` of minato v1.1.6 once `nova_liveboard_test_library`
has loaded it under that name.

`stats/1` is src/minato.erl lines 252-255, which is src/minato_pool.erl lines
570-577: a call to the process registered under the pool's name, given up
after five seconds. It exits with `{noproc, _}` when no pool has that name.
""".

-export([stats/1]).

-spec stats(atom()) -> map().
stats(Pool) ->
    case gen_server:call(Pool, stats, 5000) of
        Stats when is_map(Stats) -> Stats
    end.
