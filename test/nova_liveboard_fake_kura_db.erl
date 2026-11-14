-module(nova_liveboard_fake_kura_db).
-moduledoc """
Stands in for `kura_db` of Kura v2.30.0 once `nova_liveboard_test_library`
has loaded it under that name.

`get_pool/1` and `get_pool_module/1` have the arities, answers and raises of
src/kura_db.erl lines 279-301, read from the repo's settings as
src/kura_repo.erl lines 170-177 reads them: what Kura kept when it started
the repo's pool, which a test puts under `{kura_repo_settings, Repo}` in
`persistent_term` where Kura keeps it (src/kura_repo_settings.erl lines
18-33), and otherwise the repo's configuration.
""".

-export([get_pool/1, get_pool_module/1]).

-define(SETTINGS, [dialect, pool, pool_module, driver_module, read_only, replicas, uuid_version]).

-spec get_pool(module()) -> atom().
get_pool(RepoMod) ->
    maps:get(pool, settings(RepoMod), RepoMod).

-spec get_pool_module(module()) -> module().
get_pool_module(RepoMod) ->
    case maps:get(pool_module, settings(RepoMod), undefined) of
        PoolModule when is_atom(PoolModule), PoolModule =/= undefined -> PoolModule;
        _ -> error({no_pool_module_configured, RepoMod})
    end.

-spec settings(module()) -> map().
settings(RepoMod) ->
    case persistent_term:get({kura_repo_settings, RepoMod}, none) of
        #{} = Settings -> Settings;
        {pool_owned_by, Owner} -> error({pool_owned_by, Owner});
        {pool_not_started, Pool} -> error({pool_not_started, Pool});
        _None -> maps:with(?SETTINGS, kura_repo:config(RepoMod))
    end.
