-module(nova_liveboard_test_unnamed_app).
-moduledoc """
An application whose top supervisor is not registered as `<app>_sup`, with a
description that is not Latin-1.
""".
-behaviour(application).

-export([load/0, start/2, stop/1]).

-define(APP, nova_liveboard_test_unnamed).

-spec load() -> ok | {error, term()}.
load() ->
    application:load(
        {application, ?APP, [
            {description, "Unnamed \x{2192} top supervisor"},
            {vsn, "1.0.0"},
            {modules, [?MODULE]},
            {registered, []},
            {applications, [kernel, stdlib]},
            {mod, {?MODULE, []}}
        ]}
    ).

start(_Type, _Args) ->
    supervisor:start_link(nova_liveboard_test_redact, []).

stop(_State) ->
    ok.
