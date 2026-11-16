-module(nova_liveboard_pool_sqlite).
-moduledoc """
Figures of a `kura_pool_sqlite` pool, the pool of `kura_sqlite`.

`kura_pool_sqlite` exports the `kura_pool` callbacks, `capabilities/0` and
`dirty/2`. None of them reports what the pool holds, so there are no figures
to show for it.
""".
-behaviour(nova_liveboard_pool).

-export([backend/0, figures/1]).

-spec backend() -> binary().
backend() ->
    ~"sqlite".

-spec figures(atom()) -> nova_liveboard_pool:reading().
figures(_Pool) ->
    {not_available, ~"kura_pool_sqlite exports no function that reports pool figures"}.
