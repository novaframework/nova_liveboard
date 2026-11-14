-module(nova_liveboard_config_tests).
-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

-define(KEYS, [
    prefix,
    refresh_ms,
    request_buffer,
    max_streams,
    max_streams_per_client,
    stream_lifetime_ms,
    redact,
    trusted_origins
]).
-define(SECRET, ~"correct horse battery staple").

config_test_() ->
    {foreach, fun unset/0, fun(_) -> unset() end, [
        fun the_defaults_are_valid/0,
        fun accepted_values_pass/0,
        fun other_values_are_named/0,
        fun every_invalid_key_is_reported/0,
        fun the_failure_never_carries_the_value/0,
        fun accessors_fall_back_to_the_default/0,
        fun the_prefix_is_always_a_binary/0,
        fun the_application_refuses_to_start/0,
        fun the_router_refuses_to_mount/0
    ]}.

unset() ->
    _ = application:load(nova_liveboard),
    [application:unset_env(nova_liveboard, Key) || Key <- [auth | ?KEYS]],
    ok.

the_defaults_are_valid() ->
    ?assertEqual(ok, nova_liveboard:validate()),
    ?assertEqual(~"/liveboard", nova_liveboard:prefix()),
    ?assertEqual(200, nova_liveboard:request_buffer()).

accepted_values_pass() ->
    [
        begin
            application:set_env(nova_liveboard, Key, Value),
            ?assertEqual({Key, Value, ok}, {Key, Value, nova_liveboard:validate()}),
            application:unset_env(nova_liveboard, Key)
        end
     || {Key, Values} <- [
            {prefix, ["/liveboard", ~"/liveboard", "", ~"", "/ops/board", ~"/ops/board", "/å"]},
            {refresh_ms, [1, 2000]},
            {request_buffer, [1, 200, 100000]},
            {max_streams, [0, 1, 50]},
            {max_streams_per_client, [0, 1, 6, 50]},
            {stream_lifetime_ms, [1, 300000]},
            {redact, [standard, none, all, {nova_liveboard_test_redact, shown}]},
            {trusted_origins, [
                [], [~"https://ops.example.com", ~"http://ops.internal.example:8080"]
            ]}
        ],
        Value <- Values
    ].

other_values_are_named() ->
    [
        begin
            application:set_env(nova_liveboard, Key, Value),
            ?assertMatch(
                {Key, Value, {error, [{Key, <<_, _/binary>>}]}},
                {Key, Value, nova_liveboard:validate()}
            ),
            application:unset_env(nova_liveboard, Key)
        end
     || {Key, Values} <- [
            {prefix, [
                liveboard,
                42,
                undefined,
                "liveboard",
                ~"liveboard",
                "/",
                ~"/",
                "/liveboard/",
                ~"/liveboard/",
                ["/live", ~"board"],
                [$/, a],
                [$/ | $a],
                {~"/liveboard"}
            ]},
            {refresh_ms, [0, -1, 1.5, infinity, ~"2000", "2000", undefined]},
            {request_buffer, [0, -1, 1.5, infinity, ~"200", "200", undefined, nope]},
            {max_streams, [-1, 1.5, infinity, ~"50", undefined]},
            {max_streams_per_client, [-1, 1.5, infinity, ~"6", undefined]},
            {stream_lifetime_ms, [0, -1, 1.5, infinity, ~"300000", undefined]},
            {redact, [
                true,
                undefined,
                ~"standard",
                "none",
                {a, b, c},
                {nova_liveboard_test_redact, no_such_function},
                {nova_liveboard_no_such_module, shown},
                {nova_liveboard_test_redact, idle}
            ]},
            {trusted_origins, [
                ~"https://ops.example.com",
                ["https://ops.example.com"],
                [~"ops.example.com"],
                [~"https://"],
                [~"https://ops.example.com/"],
                [~"https://ops.example.com/board"],
                [~"https://ops.example.com", ops],
                [~"https://ops.example.com" | ~"https://b.example.com"],
                undefined
            ]}
        ],
        Value <- Values
    ].

every_invalid_key_is_reported() ->
    application:set_env(nova_liveboard, request_buffer, 0),
    application:set_env(nova_liveboard, prefix, liveboard),
    application:set_env(nova_liveboard, redact, sometimes),
    application:set_env(nova_liveboard, refresh_ms, 100),
    {error, Invalid} = nova_liveboard:validate(),
    ?assertEqual([prefix, request_buffer, redact], [Key || {Key, _Accepted} <- Invalid]).

the_failure_never_carries_the_value() ->
    Values = [
        {prefix, {?SECRET}},
        {refresh_ms, ?SECRET},
        {request_buffer, ?SECRET},
        {max_streams, ?SECRET},
        {max_streams_per_client, ?SECRET},
        {stream_lifetime_ms, ?SECRET},
        {redact, {basic, ?SECRET}},
        {trusted_origins, [<<"https://operator:", ?SECRET/binary, "@ops.example.com/">>]}
    ],
    [application:set_env(nova_liveboard, Key, Value) || {Key, Value} <- Values],
    application:set_env(nova_liveboard, auth, {basic, ~"operator", ?SECRET}),
    {error, Invalid} = nova_liveboard:validate(),
    ?assertEqual(?KEYS, [Key || {Key, _Accepted} <- Invalid]),
    Logged = [
        logged(fun() -> nova_liveboard_app:start(normal, []) end),
        logged(fun mount_failure/0),
        logged(fun() ->
            [application:unset_env(nova_liveboard, Key) || Key <- ?KEYS],
            mount_failure()
        end)
    ],
    ?assertMatch([[_ | _], [_ | _], [_ | _]], Logged),
    Failures = quiet(fun() ->
        [
            Invalid,
            nova_liveboard_app:start(normal, []),
            nova_liveboard:auth(),
            mount_failure(),
            Logged
        ]
    end),
    Printed = io_lib:format("~0tp", [Failures]),
    ?assertEqual(nomatch, string:find(Printed, "horse")),
    ?assertNotEqual(nomatch, string:find(Printed, "invalid_auth")),
    ?assertNotEqual(nomatch, string:find(Printed, "invalid_config")).

accessors_fall_back_to_the_default() ->
    [
        begin
            application:set_env(nova_liveboard, prefix, Value),
            ?assertEqual({Value, ~"/liveboard"}, {Value, nova_liveboard:prefix()})
        end
     || Value <- [liveboard, 42, [$/, a], [$/ | $a], {~"/liveboard"}, undefined]
    ],
    [
        begin
            application:set_env(nova_liveboard, request_buffer, Value),
            ?assertEqual({Value, 200}, {Value, nova_liveboard:request_buffer()})
        end
     || Value <- [0, -1, 1.5, infinity, ~"200", nope, undefined]
    ],
    application:set_env(nova_liveboard, request_buffer, nope),
    {ok, Tracer} = nova_liveboard_tracer:start_link(),
    ok = gen_server:stop(Tracer).

the_prefix_is_always_a_binary() ->
    [
        begin
            application:set_env(nova_liveboard, prefix, Value),
            ?assertEqual({Value, Prefix}, {Value, nova_liveboard:prefix()})
        end
     || {Value, Prefix} <- [
            {"/ops/board", ~"/ops/board"},
            {~"/ops/board", ~"/ops/board"},
            {"", ~""},
            {~"", ~""},
            {"/å", ~"/å"}
        ]
    ].

the_application_refuses_to_start() ->
    application:set_env(nova_liveboard, request_buffer, 0),
    quiet(fun() ->
        ?assertMatch(
            {error, {invalid_config, [{request_buffer, <<_, _/binary>>}]}},
            nova_liveboard_app:start(normal, [])
        )
    end),
    ?assertEqual(undefined, whereis(nova_liveboard_sup)),
    ?assertEqual(undefined, whereis(nova_liveboard_tracer)).

the_router_refuses_to_mount() ->
    application:set_env(nova_liveboard, auth, none),
    application:set_env(nova_liveboard, prefix, "/liveboard/"),
    quiet(fun() ->
        ?assertError(
            {nova_liveboard_refusing_to_mount, {invalid_config, [{prefix, <<_, _/binary>>}]}},
            nova_liveboard_router:routes(dev)
        )
    end),
    application:set_env(nova_liveboard, prefix, "/liveboard"),
    quiet(fun() -> ?assertMatch([#{prefix := "/liveboard"}], nova_liveboard_router:routes(dev)) end).

nova_does_not_start_on_an_invalid_setting_test() ->
    ?assertError(
        {nova_did_not_start, _},
        nova_liveboard_test_server:start([{auth, none}, {stream_lifetime_ms, forever}])
    ),
    ?assertEqual(undefined, whereis(nova_liveboard_sup)).

%% ---------------------------------------------------------------------------

mount_failure() ->
    try nova_liveboard_router:routes(dev) of
        Routes -> {mounted, Routes}
    catch
        error:Reason -> Reason
    end.

quiet(Action) ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, critical),
    try
        Action()
    after
        ok = logger:set_primary_config(level, Level)
    end.

%% Everything `Action` logs, as the events the handlers are given.
logged(Action) ->
    Test = self(),
    #{level := Level} = logger:get_primary_config(),
    ok = logger:add_handler(?MODULE, ?MODULE, #{level => all, config => Test}),
    ok = logger:set_primary_config(level, all),
    Default = logger:get_handler_config(default),
    _ = logger:set_handler_config(default, level, none),
    try
        _ = Action(),
        collect()
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

log(Event, #{config := Test}) when is_pid(Test) ->
    Test ! {logged, Event},
    ok.

collect() ->
    receive
        {logged, Event} -> [Event | collect()]
    after 100 -> []
    end.
