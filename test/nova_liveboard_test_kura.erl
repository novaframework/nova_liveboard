-module(nova_liveboard_test_kura).
-moduledoc """
A node with Kura in it, as far as the liveboard looks: an application named
`kura` with repos in its environment, `kura_repo`, `kura_db`, and minato
when a test asks for it.

The configurations are what Kura v2.30.0 keeps for a repo once it has
resolved the backend (src/kura_app.erl lines 52-58).
""".

-export([start/1, stop/0, minato/0, minato_without_stats/0, pool/2, kept/2]).
-export([postgres/1, sqlite/0, stats/0]).

-define(REPOS, [
    nova_liveboard_test_repo, nova_liveboard_test_raising_repo, shop_repo, files_repo, other_repo
]).

-spec start(#{module() => map()}) -> ok.
start(Repos) ->
    ok = stop(),
    ok = application:load(
        {application, kura, [
            {description, "Stands in for Kura"},
            {vsn, "2.30.0"},
            {modules, []},
            {registered, []},
            {applications, [kernel, stdlib]}
        ]}
    ),
    ok = application:set_env(kura, repos, Repos),
    ok = nova_liveboard_test_library:install(kura_db, nova_liveboard_fake_kura_db, []),
    [nova_liveboard_test_repo, nova_liveboard_test_raising_repo] =
        [
            Repo
         || Repo <- [nova_liveboard_test_repo, nova_liveboard_test_raising_repo],
            {module, _} <- [code:ensure_loaded(Repo)]
        ],
    ok.

-spec stop() -> ok.
stop() ->
    _ = application:unload(kura),
    ok = nova_liveboard_test_library:remove(kura_db),
    ok = nova_liveboard_test_library:remove(minato),
    _ = [persistent_term:erase({kura_repo_settings, Repo}) || Repo <- ?REPOS],
    ok.

-spec minato() -> ok.
minato() ->
    nova_liveboard_test_library:install(minato, nova_liveboard_fake_minato, []).

-spec minato_without_stats() -> ok.
minato_without_stats() ->
    nova_liveboard_test_library:install(minato, nova_liveboard_fake_minato, [{stats, 1}]).

-doc "Starts a pool registered as `Name` that answers `stats` with `State`.".
-spec pool(atom(), term()) -> pid().
pool(Name, State) ->
    {ok, Pool} = nova_liveboard_test_pool:start(Name, State),
    Pool.

-doc "What Kura keeps for a repo whose pool it started, or could not start.".
-spec kept(module(), map() | {pool_not_started, atom()} | {pool_owned_by, module()}) -> ok.
kept(Repo, Kept) ->
    persistent_term:put({kura_repo_settings, Repo}, Kept).

-spec postgres(atom()) -> map().
postgres(Pool) ->
    #{
        backend => kura_backend_postgres,
        dialect => kura_dialect_pg,
        pool_module => kura_pool_minato,
        driver_module => kura_driver_minato,
        pool => Pool,
        host => "db.internal",
        port => 5432,
        database => "shop",
        user => "shop_user",
        password => "hunter2",
        pool_size => 10
    }.

-spec sqlite() -> map().
sqlite() ->
    #{
        backend => kura_backend_sqlite,
        dialect => kura_dialect_sqlite,
        pool_module => kura_pool_sqlite,
        driver_module => kura_driver_sqlite,
        database => ~"priv/files.db",
        pool_size => 4
    }.

-doc "What `minato:stats/1` answers (minato v1.1.6 src/minato_pool.erl lines 1160-1172).".
-spec stats() -> map().
stats() ->
    #{
        size => 10,
        idle => 3,
        borrowed => 2,
        waiting => 1,
        checkouts => 120,
        waits => 7,
        timeouts => 1,
        disconnects => 4,
        retired => 2
    }.
