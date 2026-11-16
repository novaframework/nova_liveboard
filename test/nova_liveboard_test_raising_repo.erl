-module(nova_liveboard_test_raising_repo).
-moduledoc """
A Kura repo whose `init/1` fails with the configuration it was given, as one
that matches on a setting that is missing does.
""".

-export([otp_app/0, init/1]).

-spec otp_app() -> atom().
otp_app() ->
    nova_liveboard_test.

-spec init(map()) -> no_return().
init(Config) ->
    error({badmatch, Config}).
