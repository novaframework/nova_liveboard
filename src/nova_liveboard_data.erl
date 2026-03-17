-module(nova_liveboard_data).

-export([
    system_info/0,
    top_processes/2,
    ets_tables/0,
    running_applications/0,
    port_info/0,
    scheduler_info/0,
    format_bytes/1,
    format_number/1,
    format_uptime/1
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
            case erlang:process_info(Pid, [
                registered_name,
                memory,
                reductions,
                message_queue_len,
                current_function,
                initial_call,
                status
            ]) of
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
                            memory_bytes => proplists:get_value(memory, Info) * erlang:system_info(wordsize),
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
