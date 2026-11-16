-module(nova_liveboard_test_repo).
-moduledoc "A Kura repo, as the liveboard finds one among the loaded modules.".
-behaviour(kura_repo).

-export([otp_app/0]).

-spec otp_app() -> atom().
otp_app() ->
    nova_liveboard_test.
