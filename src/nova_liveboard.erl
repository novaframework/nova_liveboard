-module(nova_liveboard).

-export([prefix/0]).

-spec prefix() -> binary().
prefix() ->
    case application:get_env(nova_liveboard, prefix, ~"/liveboard") of
        Prefix when is_binary(Prefix) -> Prefix;
        Prefix when is_list(Prefix) -> list_to_binary(Prefix)
    end.
