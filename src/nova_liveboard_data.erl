-module(nova_liveboard_data).

-export([
    system_info/0,
    top_processes/2,
    ets_tables/0,
    running_applications/0,
    port_info/0,
    scheduler_info/0,
    supervision_tree/1,
    collect_metrics/1,
    sparkline_points/3,
    format_bytes/1,
    format_number/1,
    format_uptime/1,
    %% Kura
    kura_available/0,
    kura_repos/0,
    kura_repo_info/1,
    kura_pool_stats/1,
    kura_migration_status/1,
    kura_schemas/1
]).

-spec system_info() -> map().
system_info() ->
    {Total, Allocated, _Worst} = memsup_or_vm_memory(),
    #{
        otp_release => list_to_binary(erlang:system_info(otp_release)),
        erts_version => list_to_binary(erlang:system_info(version)),
        system_architecture => list_to_binary(erlang:system_info(system_architecture)),
        process_count => erlang:system_info(process_count),
        process_limit => erlang:system_info(process_limit),
        port_count => erlang:system_info(port_count),
        port_limit => erlang:system_info(port_limit),
        atom_count => erlang:system_info(atom_count),
        atom_limit => erlang:system_info(atom_limit),
        ets_count => length(ets:all()),
        scheduler_count => erlang:system_info(schedulers),
        scheduler_online => erlang:system_info(schedulers_online),
        uptime => element(1, erlang:statistics(wall_clock)),
        total_memory => Total,
        allocated_memory => Allocated,
        memory => memory_info()
    }.

-spec memory_info() -> map().
memory_info() ->
    Mem = erlang:memory(),
    #{
        total => proplists:get_value(total, Mem),
        processes => proplists:get_value(processes, Mem),
        processes_used => proplists:get_value(processes_used, Mem),
        system => proplists:get_value(system, Mem),
        atom => proplists:get_value(atom, Mem),
        atom_used => proplists:get_value(atom_used, Mem),
        binary => proplists:get_value(binary, Mem),
        code => proplists:get_value(code, Mem),
        ets => proplists:get_value(ets, Mem)
    }.

-spec top_processes(SortBy, Limit) -> [map()] when
    SortBy :: memory | reductions | message_queue_len,
    Limit :: pos_integer().
top_processes(SortBy, Limit) ->
    Procs = erlang:processes(),
    ProcInfos = lists:filtermap(
        fun(Pid) ->
            case
                erlang:process_info(Pid, [
                    registered_name,
                    memory,
                    reductions,
                    message_queue_len,
                    current_function,
                    initial_call,
                    status
                ])
            of
                undefined ->
                    false;
                Info ->
                    {true, proc_to_map(Pid, Info)}
            end
        end,
        Procs
    ),
    Sorted = lists:sort(
        fun(A, B) -> maps:get(SortBy, A) >= maps:get(SortBy, B) end,
        ProcInfos
    ),
    lists:sublist(Sorted, Limit).

-spec ets_tables() -> [map()].
ets_tables() ->
    Tables = ets:all(),
    lists:filtermap(
        fun(Tab) ->
            try
                Info = ets:info(Tab),
                case Info of
                    undefined ->
                        false;
                    _ ->
                        {true, #{
                            id => format_ets_id(Tab),
                            name => atom_to_binary(proplists:get_value(name, Info)),
                            size => proplists:get_value(size, Info),
                            memory_words => proplists:get_value(memory, Info),
                            memory_bytes => proplists:get_value(memory, Info) *
                                erlang:system_info(wordsize),
                            owner => format_pid(proplists:get_value(owner, Info)),
                            type => atom_to_binary(proplists:get_value(type, Info)),
                            protection => atom_to_binary(proplists:get_value(protection, Info))
                        }}
                end
            catch
                _:_ -> false
            end
        end,
        Tables
    ).

-spec running_applications() -> [map()].
running_applications() ->
    Apps = application:which_applications(),
    [
        #{
            name => atom_to_binary(Name),
            description => list_to_binary(Desc),
            version => list_to_binary(Vsn)
        }
     || {Name, Desc, Vsn} <- lists:sort(Apps)
    ].

-spec port_info() -> [map()].
port_info() ->
    Ports = erlang:ports(),
    lists:filtermap(
        fun(Port) ->
            try
                Info = erlang:port_info(Port),
                case Info of
                    undefined ->
                        false;
                    _ ->
                        {true, #{
                            id => format_port(Port),
                            name => list_to_binary(proplists:get_value(name, Info, "")),
                            connected => format_pid(proplists:get_value(connected, Info)),
                            input => proplists:get_value(input, Info, 0),
                            output => proplists:get_value(output, Info, 0)
                        }}
                end
            catch
                _:_ -> false
            end
        end,
        Ports
    ).

-spec scheduler_info() -> [map()].
scheduler_info() ->
    Count = erlang:system_info(schedulers),
    lists:map(
        fun(I) ->
            {_, Active} = erlang:statistics({scheduler_wall_time_all, I}),
            #{id => I, active => Active}
        end,
        lists:seq(1, Count)
    ).

-spec supervision_tree(atom()) -> {ok, list()} | {error, term()}.
supervision_tree(AppName) ->
    case find_top_supervisor(AppName) of
        undefined -> {error, no_supervisor};
        Pid -> {ok, build_tree(Pid)}
    end.

-spec collect_metrics(undefined | map()) -> map().
collect_metrics(undefined) ->
    erlang:system_flag(scheduler_wall_time, true),
    Mem = erlang:memory(),
    {{input, In}, {output, Out}} = erlang:statistics(io),
    SchedWall = scheduler_wall_time(),
    #{
        total_memory => queue:from_list([proplists:get_value(total, Mem)]),
        process_memory => queue:from_list([proplists:get_value(processes, Mem)]),
        binary_memory => queue:from_list([proplists:get_value(binary, Mem)]),
        process_count => queue:from_list([erlang:system_info(process_count)]),
        run_queue => queue:from_list([erlang:statistics(run_queue)]),
        io_input => queue:from_list([0]),
        io_output => queue:from_list([0]),
        scheduler_util => [],
        prev_io => {In, Out},
        prev_sched => SchedWall,
        max_points => 60
    };
collect_metrics(
    #{max_points := MaxPts, prev_io := {PrevIn, PrevOut}, prev_sched := PrevSched} = State
) ->
    Mem = erlang:memory(),
    {{input, In}, {output, Out}} = erlang:statistics(io),
    SchedWall = scheduler_wall_time(),
    SchedUtil = calc_sched_util(PrevSched, SchedWall),
    Append = fun(Key, Val, S) ->
        Q0 = maps:get(Key, S),
        Q1 = queue:in(Val, Q0),
        Q2 =
            case queue:len(Q1) > MaxPts of
                true -> element(2, queue:out(Q1));
                false -> Q1
            end,
        maps:put(Key, Q2, S)
    end,
    S1 = Append(total_memory, proplists:get_value(total, Mem), State),
    S2 = Append(process_memory, proplists:get_value(processes, Mem), S1),
    S3 = Append(binary_memory, proplists:get_value(binary, Mem), S2),
    S4 = Append(process_count, erlang:system_info(process_count), S3),
    S5 = Append(run_queue, erlang:statistics(run_queue), S4),
    S6 = Append(io_input, In - PrevIn, S5),
    S7 = Append(io_output, Out - PrevOut, S6),
    S7#{prev_io => {In, Out}, prev_sched => SchedWall, scheduler_util => SchedUtil}.

-spec sparkline_points(list(), number(), number()) -> binary().
sparkline_points([], _Width, _Height) ->
    ~"";
sparkline_points([_], Width, Height) ->
    iolist_to_binary(io_lib:format("0,~.1f ~.1f,~.1f", [Height / 2.0, float(Width), Height / 2.0]));
sparkline_points(Values, Width, Height) ->
    Min = lists:min(Values),
    Max = lists:max(Values),
    Range =
        case Max - Min of
            0 -> 1;
            R -> R
        end,
    Len = length(Values),
    Step = Width / max(1, Len - 1),
    {Points, _} = lists:foldl(
        fun(V, {Acc, I}) ->
            X = I * Step,
            Y = Height - ((V - Min) / Range * Height),
            Pt = io_lib:format("~.1f,~.1f", [float(X), float(Y)]),
            Sep =
                case Acc of
                    [] -> [];
                    _ -> [Acc, " "]
                end,
            {[Sep, Pt], I + 1}
        end,
        {[], 0},
        Values
    ),
    iolist_to_binary(Points).

%%----------------------------------------------------------------------
%% Kura
%%----------------------------------------------------------------------

-spec kura_available() -> boolean().
kura_available() ->
    case application:get_key(kura, vsn) of
        {ok, _} -> true;
        undefined -> false
    end.

-spec kura_repos() -> [module()].
kura_repos() ->
    case kura_available() of
        false ->
            [];
        true ->
            [
                M
             || {M, _} <- code:all_loaded(),
                is_kura_repo(M)
            ]
    end.

-spec kura_repo_info(module()) -> map().
kura_repo_info(RepoMod) ->
    Config = kura_repo:config(RepoMod),
    #{
        module => atom_to_binary(RepoMod),
        database => maps:get(database, Config, ~"unknown"),
        hostname => maps:get(hostname, Config, ~"localhost"),
        port => maps:get(port, Config, 5432),
        pool_size => maps:get(pool_size, Config, 10),
        pool => maps:get(pool, Config, RepoMod)
    }.

-spec kura_pool_stats(atom()) -> map().
kura_pool_stats(PoolName) ->
    try
        PoolPid = whereis(PoolName),
        case PoolPid of
            undefined ->
                #{status => ~"down", available => 0, checked_out => 0, queued => 0};
            _ ->
                pool_stats_from_pid(PoolPid, PoolName)
        end
    catch
        _:_ ->
            #{status => ~"unknown", available => 0, checked_out => 0, queued => 0}
    end.

-spec kura_migration_status(module()) -> [map()].
kura_migration_status(RepoMod) ->
    try
        Status = kura_migrator:status(RepoMod),
        [
            #{
                version => integer_to_binary(V),
                module => atom_to_binary(M),
                status => atom_to_binary(S)
            }
         || {V, M, S} <- Status
        ]
    catch
        _:_ -> []
    end.

-spec kura_schemas(module()) -> [map()].
kura_schemas(RepoMod) ->
    case application:get_application(RepoMod) of
        {ok, App} ->
            case application:get_key(App, modules) of
                {ok, Modules} ->
                    lists:filtermap(
                        fun(M) ->
                            case is_kura_schema(M) of
                                true -> {true, schema_info(M)};
                                false -> false
                            end
                        end,
                        lists:sort(Modules)
                    );
                _ ->
                    []
            end;
        undefined ->
            []
    end.

%% Internal

memsup_or_vm_memory() ->
    Mem = erlang:memory(),
    Total = proplists:get_value(total, Mem),
    {Total, Total, 0}.

proc_to_map(Pid, Info) ->
    Name =
        case proplists:get_value(registered_name, Info) of
            [] -> format_pid(Pid);
            RegName -> atom_to_binary(RegName)
        end,
    #{
        pid => format_pid(Pid),
        name => Name,
        memory => proplists:get_value(memory, Info),
        reductions => proplists:get_value(reductions, Info),
        message_queue_len => proplists:get_value(message_queue_len, Info),
        current_function => format_mfa(proplists:get_value(current_function, Info)),
        initial_call => format_mfa(proplists:get_value(initial_call, Info)),
        status => atom_to_binary(proplists:get_value(status, Info))
    }.

format_pid(Pid) ->
    list_to_binary(pid_to_list(Pid)).

format_port(Port) ->
    list_to_binary(erlang:port_to_list(Port)).

format_mfa({M, F, A}) ->
    iolist_to_binary(io_lib:format("~s:~s/~b", [M, F, A]));
format_mfa(_) ->
    ~"unknown".

format_ets_id(Tab) when is_atom(Tab) ->
    atom_to_binary(Tab);
format_ets_id(Tab) when is_reference(Tab) ->
    list_to_binary(ref_to_list(Tab));
format_ets_id(Tab) ->
    iolist_to_binary(io_lib:format("~p", [Tab])).

-spec format_bytes(non_neg_integer()) -> binary().
format_bytes(Bytes) when Bytes >= 1073741824 ->
    iolist_to_binary(io_lib:format("~.1f GB", [Bytes / 1073741824]));
format_bytes(Bytes) when Bytes >= 1048576 ->
    iolist_to_binary(io_lib:format("~.1f MB", [Bytes / 1048576]));
format_bytes(Bytes) when Bytes >= 1024 ->
    iolist_to_binary(io_lib:format("~.1f KB", [Bytes / 1024]));
format_bytes(Bytes) ->
    iolist_to_binary(io_lib:format("~B B", [Bytes])).

-spec format_number(non_neg_integer()) -> binary().
format_number(N) when N >= 1000000 ->
    iolist_to_binary(io_lib:format("~.1fM", [N / 1000000]));
format_number(N) when N >= 1000 ->
    iolist_to_binary(io_lib:format("~.1fK", [N / 1000]));
format_number(N) ->
    integer_to_binary(N).

-spec format_uptime(non_neg_integer()) -> binary().
format_uptime(Ms) ->
    Secs = Ms div 1000,
    Days = Secs div 86400,
    Hours = (Secs rem 86400) div 3600,
    Mins = (Secs rem 3600) div 60,
    S = Secs rem 60,
    iolist_to_binary(
        case Days of
            0 -> io_lib:format("~2..0B:~2..0B:~2..0B", [Hours, Mins, S]);
            _ -> io_lib:format("~Bd ~2..0B:~2..0B:~2..0B", [Days, Hours, Mins, S])
        end
    ).

find_top_supervisor(AppName) ->
    case try_named_sup(AppName) of
        Pid when is_pid(Pid) -> Pid;
        undefined -> find_sup_via_master(AppName)
    end.

try_named_sup(AppName) ->
    SupStr = atom_to_list(AppName) ++ "_sup",
    try list_to_existing_atom(SupStr) of
        SupName -> whereis(SupName)
    catch
        error:badarg -> undefined
    end.

find_sup_via_master(AppName) ->
    try application_controller:get_master(AppName) of
        MasterPid when is_pid(MasterPid) ->
            %% application_master links to: application_controller + a starter process
            %% The starter process links to the top supervisor
            case erlang:process_info(MasterPid, links) of
                {links, Links} ->
                    find_sup_in_master_links(Links);
                _ ->
                    undefined
            end;
        _ ->
            undefined
    catch
        _:_ -> undefined
    end.

find_sup_in_master_links([]) ->
    undefined;
find_sup_in_master_links([Pid | Rest]) when is_pid(Pid) ->
    %% Skip the application_controller itself
    case Pid =:= whereis(application_controller) of
        true ->
            find_sup_in_master_links(Rest);
        false ->
            %% This is the starter process; its child is the top supervisor
            case erlang:process_info(Pid, links) of
                {links, ChildLinks} ->
                    find_first_supervisor(ChildLinks);
                _ ->
                    find_sup_in_master_links(Rest)
            end
    end;
find_sup_in_master_links([_ | Rest]) ->
    find_sup_in_master_links(Rest).

find_first_supervisor([]) ->
    undefined;
find_first_supervisor([Pid | Rest]) when is_pid(Pid) ->
    try supervisor:which_children(Pid) of
        _ -> Pid
    catch
        _:_ -> find_first_supervisor(Rest)
    end;
find_first_supervisor([_ | Rest]) ->
    find_first_supervisor(Rest).

build_tree(Pid) ->
    try supervisor:which_children(Pid) of
        Children ->
            lists:map(
                fun({Id, ChildPid, Type, _Mods}) ->
                    Base = #{
                        type => Type,
                        name => format_child_id(Id),
                        pid => format_child_pid(ChildPid),
                        status => child_status(ChildPid)
                    },
                    ProcInfo = child_proc_info(ChildPid),
                    WithInfo = maps:merge(Base, ProcInfo),
                    case Type of
                        supervisor when is_pid(ChildPid) ->
                            WithInfo#{children => build_tree(ChildPid)};
                        _ ->
                            WithInfo#{children => []}
                    end
                end,
                Children
            )
    catch
        _:_ -> []
    end.

format_child_id(Id) when is_atom(Id) -> atom_to_binary(Id);
format_child_id(Id) -> iolist_to_binary(io_lib:format("~p", [Id])).

format_child_pid(Pid) when is_pid(Pid) -> list_to_binary(pid_to_list(Pid));
format_child_pid(undefined) -> ~"undefined";
format_child_pid(restarting) -> ~"restarting";
format_child_pid(_) -> ~"unknown".

child_status(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, status) of
        {status, S} -> atom_to_binary(S);
        undefined -> ~"dead"
    end;
child_status(restarting) ->
    ~"restarting";
child_status(_) ->
    ~"stopped".

child_proc_info(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, [memory, message_queue_len, current_function]) of
        undefined ->
            #{memory => 0, message_queue_len => 0, current_function => ~"unknown"};
        Info ->
            #{
                memory => proplists:get_value(memory, Info, 0),
                message_queue_len => proplists:get_value(message_queue_len, Info, 0),
                current_function => format_mfa(proplists:get_value(current_function, Info))
            }
    end;
child_proc_info(_) ->
    #{memory => 0, message_queue_len => 0, current_function => ~"—"}.

scheduler_wall_time() ->
    try erlang:statistics(scheduler_wall_time) of
        undefined -> [];
        List when is_list(List) -> lists:sort(List);
        _ -> []
    catch
        _:_ -> []
    end.

calc_sched_util([], _) ->
    [];
calc_sched_util(_, []) ->
    [];
calc_sched_util(Prev, Curr) ->
    Map = maps:from_list([{I, {A, T}} || {I, A, T} <- Prev]),
    lists:filtermap(
        fun({I, A1, T1}) ->
            case maps:find(I, Map) of
                {ok, {A0, T0}} ->
                    DT = T1 - T0,
                    Util =
                        case DT of
                            0 -> 0.0;
                            _ -> (A1 - A0) / DT * 100
                        end,
                    {true, #{id => I, util => Util}};
                error ->
                    false
            end
        end,
        Curr
    ).

is_kura_repo(Mod) ->
    try
        Behaviours = proplists:get_value(behaviour, Mod:module_info(attributes), []),
        lists:member(kura_repo, Behaviours)
    catch
        _:_ -> false
    end.

is_kura_schema(Mod) ->
    try
        Behaviours = proplists:get_value(behaviour, Mod:module_info(attributes), []),
        lists:member(kura_schema, Behaviours)
    catch
        _:_ -> false
    end.

schema_info(Mod) ->
    Fields =
        try Mod:fields() of
            Fs -> [field_info(F) || F <- Fs]
        catch
            _:_ -> []
        end,
    Assocs =
        try kura_schema:associations(Mod) of
            As -> [assoc_info(A) || A <- As]
        catch
            _:_ -> []
        end,
    Indexes =
        try kura_schema:indexes(Mod) of
            Is -> [index_info(I) || I <- Is]
        catch
            _:_ -> []
        end,
    #{
        module => atom_to_binary(Mod),
        table =>
            try
                Mod:table()
            catch
                _:_ -> ~"unknown"
            end,
        fields => Fields,
        associations => Assocs,
        indexes => Indexes
    }.

field_info({kura_field, Name, Type, _Col, _Default, PK, _Nullable, Virtual}) ->
    #{
        name => atom_to_binary(Name),
        type => format_kura_type(Type),
        primary_key => PK,
        virtual => Virtual
    }.

assoc_info({kura_assoc, Name, Type, Schema, _FK, _JoinThrough, _JoinKeys}) ->
    #{
        name => atom_to_binary(Name),
        type => atom_to_binary(Type),
        schema => atom_to_binary(Schema)
    }.

index_info({Columns, Opts}) when is_map(Opts) ->
    #{
        columns => [atom_to_binary(C) || C <- Columns],
        unique => maps:get(unique, Opts, false)
    };
index_info({Columns, _}) ->
    #{
        columns => [atom_to_binary(C) || C <- Columns],
        unique => false
    }.

format_kura_type(id) ->
    ~"id";
format_kura_type(integer) ->
    ~"integer";
format_kura_type(float) ->
    ~"float";
format_kura_type(string) ->
    ~"string";
format_kura_type(text) ->
    ~"text";
format_kura_type(boolean) ->
    ~"boolean";
format_kura_type(date) ->
    ~"date";
format_kura_type(utc_datetime) ->
    ~"utc_datetime";
format_kura_type(uuid) ->
    ~"uuid";
format_kura_type(jsonb) ->
    ~"jsonb";
format_kura_type({enum, Vals}) ->
    iolist_to_binary([~"enum(", lists:join(~", ", [atom_to_binary(V) || V <- Vals]), ~")"]);
format_kura_type({array, Inner}) ->
    iolist_to_binary([~"array(", format_kura_type(Inner), ~")"]);
format_kura_type({embed, Kind, Mod}) ->
    iolist_to_binary([atom_to_binary(Kind), ~"(", atom_to_binary(Mod), ~")"]);
format_kura_type(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

pool_stats_from_pid(PoolPid, PoolName) ->
    try sys:get_state(PoolPid) of
        {State, Tid, Codel} when is_atom(State), is_reference(Tid), is_map(Codel) ->
            QueueSize = ets:info(Tid, size),
            PoolSize = pool_size_from_sup(PoolName),
            case State of
                ready ->
                    #{
                        status => ~"ready",
                        available => QueueSize,
                        checked_out => max(0, PoolSize - QueueSize),
                        queued => 0,
                        delay => maps:get(delay, Codel, 0)
                    };
                busy ->
                    #{
                        status => ~"busy",
                        available => 0,
                        checked_out => PoolSize,
                        queued => QueueSize,
                        delay => maps:get(delay, Codel, 0)
                    }
            end;
        _ ->
            #{status => ~"unknown", available => 0, checked_out => 0, queued => 0}
    catch
        _:_ ->
            #{status => ~"unknown", available => 0, checked_out => 0, queued => 0}
    end.

pool_size_from_sup(PoolName) ->
    try
        SupName = list_to_existing_atom(atom_to_list(PoolName) ++ "_sup"),
        case whereis(SupName) of
            undefined ->
                0;
            SupPid ->
                ConnSup = find_connection_sup(SupPid),
                case ConnSup of
                    undefined ->
                        0;
                    Pid ->
                        Counts = supervisor:count_children(Pid),
                        proplists:get_value(active, Counts, 0)
                end
        end
    catch
        _:_ -> 0
    end.

find_connection_sup(SupPid) ->
    try supervisor:which_children(SupPid) of
        Children ->
            case [Pid || {pgo_connection_sup, Pid, _, _} <- Children, is_pid(Pid)] of
                [Pid | _] -> Pid;
                [] -> undefined
            end
    catch
        _:_ -> undefined
    end.
