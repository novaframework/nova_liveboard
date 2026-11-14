-module(nova_liveboard_test_unnamed_app).
-moduledoc """
An application whose top supervisor is not registered as `<app>_sup`, with a
description that is not Latin-1 and a Kura schema among its modules.
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
            {modules, [?MODULE, nova_liveboard_test_schema]},
            {registered, []},
            {applications, [kernel, stdlib]},
            {mod, {?MODULE, []}}
        ]}
    ).

-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_Type, _Args) ->
    {ok, Supervisor} = supervisor:start_link(nova_liveboard_test_redact, []),
    {ok, Supervisor}.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
