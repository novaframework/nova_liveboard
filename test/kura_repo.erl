-module(kura_repo).
-moduledoc """
Stands in for Kura's module of the same name, which the liveboard calls when
it finds it in the node. Kura is not a dependency.

`config/1` answers what Kura v2.30.0 answers for a repo in the
`{repos, #{Repo => Config}}` map of the `kura` application (src/kura_repo.erl
lines 149-155 and 206-211): the whole configuration, password included, with
the repo's `init/1` applied when it exports one.
""".

-export([config/1]).

-callback otp_app() -> atom().
-callback init(Config :: map()) -> map().

-optional_callbacks([init/1]).

-spec config(module()) -> map().
config(RepoMod) ->
    Config =
        case application:get_env(kura, repos) of
            {ok, #{RepoMod := Configured}} when is_map(Configured) -> Configured;
            _ -> #{}
        end,
    case erlang:function_exported(RepoMod, init, 1) of
        true -> RepoMod:init(Config);
        false -> Config
    end.
