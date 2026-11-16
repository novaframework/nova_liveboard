-module(nova_liveboard_test_log).
-moduledoc "Collects what is logged while a test runs.".

-export([logged/1, log/2]).

-doc "Everything `Action` logs, as the events the handlers are given, printed.".
-spec logged(fun(() -> term())) -> binary().
logged(Action) ->
    Test = self(),
    #{level := Level} = logger:get_primary_config(),
    ok = logger:add_handler(?MODULE, ?MODULE, #{level => all, config => Test}),
    ok = logger:set_primary_config(level, all),
    Default = logger:get_handler_config(default),
    _ = logger:set_handler_config(default, level, none),
    try
        _ = Action(),
        iolist_to_binary(io_lib:format("~0tp", [collect()]))
    after
        ok = logger:set_primary_config(level, Level),
        ok = logger:remove_handler(?MODULE),
        case Default of
            {ok, #{level := DefaultLevel}} ->
                ok = logger:set_handler_config(default, level, DefaultLevel);
            _ ->
                ok
        end
    end.

-doc false.
-spec log(logger:log_event(), logger:handler_config()) -> ok.
log(Event, #{config := Test}) when is_pid(Test) ->
    Test ! {logged, Event},
    ok;
log(_Event, _Config) ->
    ok.

-spec collect() -> [term()].
collect() ->
    receive
        {logged, Event} -> [Event | collect()]
    after 100 -> []
    end.
