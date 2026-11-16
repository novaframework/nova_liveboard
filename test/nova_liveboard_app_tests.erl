-module(nova_liveboard_app_tests).
-include_lib("eunit/include/eunit.hrl").

%% `auth` has no default on purpose: the host has to choose.
the_env_block_states_every_default_test() ->
    Env = app_key(env),
    Keys = [Key || {Key, _Default} <- Env],
    ?assertEqual(
        [
            max_streams,
            max_streams_per_client,
            prefix,
            redact,
            refresh_ms,
            request_buffer,
            stream_lifetime_ms,
            trusted_origins
        ],
        lists:sort(Keys)
    ),
    [application:unset_env(nova_liveboard, Key) || Key <- Keys],
    Unset = [{Key, nova_liveboard:Key()} || Key <- Keys],
    [application:set_env(nova_liveboard, Key, Default) || {Key, Default} <- Env],
    try
        ?assertEqual(ok, nova_liveboard:validate()),
        ?assertEqual(Unset, [{Key, nova_liveboard:Key()} || Key <- Keys])
    after
        [application:unset_env(nova_liveboard, Key) || Key <- Keys]
    end.

every_registered_name_is_declared_test() ->
    {ok, Sup} = nova_liveboard_sup:start_link(),
    true = unlink(Sup),
    Names = [
        registered_name(Pid)
     || Pid <- [Sup | [Child || {_Id, Child, _Type, _Modules} <- supervisor:which_children(Sup)]]
    ],
    ok = gen_server:stop(Sup),
    ?assertEqual(3, length(Names)),
    ?assertEqual(lists:sort(Names), lists:sort(app_key(registered))).

registered_name(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, registered_name) of
        {registered_name, Name} when is_atom(Name) -> Name
    end.

app_key(Key) ->
    _ = application:load(nova_liveboard),
    case code:lib_dir(nova_liveboard) of
        LibDir when is_list(LibDir) ->
            {ok, [{application, nova_liveboard, Properties}]} =
                file:consult(filename:join([LibDir, "ebin", "nova_liveboard.app"])),
            case lists:keyfind(Key, 1, Properties) of
                {Key, Value} when is_list(Value) -> Value
            end
    end.
