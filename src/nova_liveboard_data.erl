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

-type sort_key() :: memory | reductions | message_queue_len.
-type memory() :: #{
    total := non_neg_integer(),
    processes := non_neg_integer(),
    processes_used := non_neg_integer(),
    system := non_neg_integer(),
    atom := non_neg_integer(),
    atom_used := non_neg_integer(),
    binary := non_neg_integer(),
    code := non_neg_integer(),
    ets := non_neg_integer()
}.
-type system() :: #{
    otp_release := binary(),
    erts_version := binary(),
    system_architecture := binary(),
    process_count := non_neg_integer(),
    process_limit := pos_integer(),
    port_count := non_neg_integer(),
    port_limit := pos_integer(),
    atom_count := pos_integer(),
    atom_limit := pos_integer(),
    run_queue := non_neg_integer(),
    ets_count := non_neg_integer(),
    scheduler_count := pos_integer(),
    scheduler_online := pos_integer(),
    uptime := non_neg_integer(),
    total_memory := non_neg_integer(),
    allocated_memory := non_neg_integer(),
    memory := memory()
}.
-type process() :: #{
    pid := binary(),
    name := binary(),
    memory := non_neg_integer(),
    reductions := non_neg_integer(),
    message_queue_len := non_neg_integer(),
    current_function := binary(),
    initial_call := binary(),
    status := binary()
}.
-type ets_table() :: #{
    id := binary(),
    name := binary(),
    size := non_neg_integer(),
    memory_words := non_neg_integer(),
    memory_bytes := non_neg_integer(),
    owner := binary(),
    type := binary(),
    protection := binary()
}.
-type application() :: #{name := binary(), description := binary(), version := binary()}.
-type open_port() :: #{
    id := binary(),
    name := binary(),
    connected := binary(),
    input := non_neg_integer(),
    output := non_neg_integer()
}.
-type scheduler() :: #{id := pos_integer(), active := non_neg_integer()}.
-type child() :: #{
    type := supervisor | worker,
    name := binary(),
    pid := binary(),
    status := binary(),
    memory := non_neg_integer(),
    message_queue_len := non_neg_integer(),
    current_function := binary(),
    children := [child()]
}.
-type wall_time() :: [{pos_integer(), non_neg_integer(), non_neg_integer()}].
-type metrics() :: #{
    total_memory := queue:queue(non_neg_integer()),
    process_memory := queue:queue(non_neg_integer()),
    binary_memory := queue:queue(non_neg_integer()),
    process_count := queue:queue(non_neg_integer()),
    run_queue := queue:queue(non_neg_integer()),
    io_input := queue:queue(integer()),
    io_output := queue:queue(integer()),
    scheduler_util := [#{id := pos_integer(), util := float()}],
    prev_io := {non_neg_integer(), non_neg_integer()},
    prev_sched := wall_time(),
    max_points := pos_integer()
}.
-type repo() :: #{
    module := binary(),
    database := term(),
    hostname := term(),
    port := term(),
    pool_size := term(),
    pool := term()
}.
-type pool_stats() :: #{
    status := binary(),
    available := non_neg_integer(),
    checked_out := non_neg_integer(),
    queued := non_neg_integer(),
    delay => term()
}.
-type migration() :: #{version := binary(), module := binary(), status := binary()}.
-type schema() :: #{
    module := binary(),
    table := term(),
    fields := [#{name := binary(), type := binary(), primary_key := term(), virtual := term()}],
    associations := [#{name := binary(), type := binary(), schema := binary()}],
    indexes := [#{columns := [binary()], unique := term()}]
}.

-export_type([
    sort_key/0,
    memory/0,
    system/0,
    process/0,
    ets_table/0,
    application/0,
    open_port/0,
    scheduler/0,
    child/0,
    metrics/0,
    repo/0,
    pool_stats/0,
    migration/0,
    schema/0
]).

-spec system_info() -> system().
system_info() ->
    Memory = memory_info(),
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
        run_queue => erlang:statistics(run_queue),
        ets_count => length(ets:all()),
        scheduler_count => erlang:system_info(schedulers),
        scheduler_online => erlang:system_info(schedulers_online),
        uptime => uptime(),
        total_memory => maps:get(total, Memory),
        allocated_memory => maps:get(total, Memory),
        memory => Memory
    }.

-spec uptime() -> non_neg_integer().
uptime() ->
    {Total, _SinceLastCall} = erlang:statistics(wall_clock),
    Total.

-spec memory_info() -> memory().
memory_info() ->
    Memory = erlang:memory(),
    #{
        total => bytes(total, Memory),
        processes => bytes(processes, Memory),
        processes_used => bytes(processes_used, Memory),
        system => bytes(system, Memory),
        atom => bytes(atom, Memory),
        atom_used => bytes(atom_used, Memory),
        binary => bytes(binary, Memory),
        code => bytes(code, Memory),
        ets => bytes(ets, Memory)
    }.

-spec bytes(atom(), [{atom(), non_neg_integer()}]) -> non_neg_integer().
bytes(Type, Memory) ->
    case lists:keyfind(Type, 1, Memory) of
        {Type, Bytes} -> Bytes;
        false -> 0
    end.

-spec top_processes(sort_key(), pos_integer()) -> [process()].
top_processes(SortBy, Limit) ->
    Processes = [
        process(Pid, Info)
     || Pid <- erlang:processes(),
        Info <- [
            erlang:process_info(Pid, [
                registered_name,
                memory,
                reductions,
                message_queue_len,
                current_function,
                initial_call,
                status
            ])
        ],
        Info =/= undefined
    ],
    Sorted = lists:sort(
        fun(A, B) -> sort_value(SortBy, A) >= sort_value(SortBy, B) end,
        Processes
    ),
    lists:sublist(Sorted, Limit).

-spec sort_value(sort_key(), process()) -> non_neg_integer().
sort_value(memory, #{memory := Memory}) -> Memory;
sort_value(reductions, #{reductions := Reductions}) -> Reductions;
sort_value(message_queue_len, #{message_queue_len := Length}) -> Length.

-spec ets_tables() -> [ets_table()].
ets_tables() ->
    [Table || Id <- ets:all(), {ok, Table} <- [ets_table(Id)]].

%% A table can be deleted between `ets:all/0` and `ets:info/1`.
-spec ets_table(ets:table()) -> {ok, ets_table()} | gone.
ets_table(Id) ->
    try ets:info(Id) of
        undefined ->
            gone;
        Info ->
            case
                {
                    proplists:get_value(name, Info),
                    proplists:get_value(size, Info),
                    proplists:get_value(memory, Info),
                    proplists:get_value(owner, Info),
                    proplists:get_value(type, Info),
                    proplists:get_value(protection, Info)
                }
            of
                {Name, Size, Words, Owner, Type, Protection} when
                    is_atom(Name),
                    is_integer(Size),
                    Size >= 0,
                    is_integer(Words),
                    Words >= 0,
                    is_pid(Owner),
                    is_atom(Type),
                    is_atom(Protection)
                ->
                    {ok, #{
                        id => format_ets_id(Id),
                        name => atom_to_binary(Name),
                        size => Size,
                        memory_words => Words,
                        memory_bytes => Words * erlang:system_info(wordsize),
                        owner => format_pid(Owner),
                        type => atom_to_binary(Type),
                        protection => atom_to_binary(Protection)
                    }};
                _ ->
                    gone
            end
    catch
        error:badarg -> gone
    end.

-spec running_applications() -> [application()].
running_applications() ->
    [
        #{
            name => atom_to_binary(Name),
            description => unicode_binary(Description),
            version => unicode_binary(Version)
        }
     || {Name, Description, Version} <- lists:sort(application:which_applications())
    ].

-spec port_info() -> [open_port()].
port_info() ->
    [Port || Id <- erlang:ports(), {ok, Port} <- [open_port(Id)]].

%% A port can be closed between `erlang:ports/0` and `erlang:port_info/2`.
-spec open_port(port()) -> {ok, open_port()} | closed.
open_port(Id) ->
    try
        {
            erlang:port_info(Id, name),
            erlang:port_info(Id, connected),
            erlang:port_info(Id, input),
            erlang:port_info(Id, output)
        }
    of
        {{name, Name}, {connected, Connected}, {input, Input}, {output, Output}} ->
            {ok, #{
                id => format_port(Id),
                name => nova_liveboard_redact:port_name(unicode_binary(Name)),
                connected => format_pid(Connected),
                input => Input,
                output => Output
            }};
        _ ->
            closed
    catch
        error:badarg -> closed
    end.

-doc """
The active time of every scheduler, from `scheduler_wall_time_all`. Empty
until the `scheduler_wall_time` flag is on, which `collect_metrics/1` turns
on.
""".
-spec scheduler_info() -> [scheduler()].
scheduler_info() ->
    case erlang:statistics(scheduler_wall_time_all) of
        undefined ->
            [];
        Schedulers ->
            [#{id => Id, active => Active} || {Id, Active, _Total} <- lists:sort(Schedulers)]
    end.

-spec supervision_tree(atom()) -> {ok, [child()]} | {error, no_supervisor}.
supervision_tree(AppName) ->
    case find_top_supervisor(AppName) of
        undefined -> {error, no_supervisor};
        Pid -> {ok, build_tree(Pid)}
    end.

-spec collect_metrics(undefined | metrics()) -> metrics().
collect_metrics(undefined) ->
    _ = erlang:system_flag(scheduler_wall_time, true),
    Memory = erlang:memory(),
    {{input, In}, {output, Out}} = erlang:statistics(io),
    #{
        total_memory => queue:from_list([bytes(total, Memory)]),
        process_memory => queue:from_list([bytes(processes, Memory)]),
        binary_memory => queue:from_list([bytes(binary, Memory)]),
        process_count => queue:from_list([erlang:system_info(process_count)]),
        run_queue => queue:from_list([erlang:statistics(run_queue)]),
        io_input => queue:from_list([0]),
        io_output => queue:from_list([0]),
        scheduler_util => [],
        prev_io => {In, Out},
        prev_sched => scheduler_wall_time(),
        max_points => 60
    };
collect_metrics(
    #{
        total_memory := TotalMemory,
        process_memory := ProcessMemory,
        binary_memory := BinaryMemory,
        process_count := ProcessCount,
        run_queue := RunQueue,
        io_input := Input,
        io_output := Output,
        prev_io := {PrevIn, PrevOut},
        prev_sched := PrevSched,
        max_points := Max
    } = Metrics
) ->
    Memory = erlang:memory(),
    {{input, In}, {output, Out}} = erlang:statistics(io),
    SchedWall = scheduler_wall_time(),
    Metrics#{
        total_memory := sampled(bytes(total, Memory), TotalMemory, Max),
        process_memory := sampled(bytes(processes, Memory), ProcessMemory, Max),
        binary_memory := sampled(bytes(binary, Memory), BinaryMemory, Max),
        process_count := sampled(erlang:system_info(process_count), ProcessCount, Max),
        run_queue := sampled(erlang:statistics(run_queue), RunQueue, Max),
        io_input := sampled(In - PrevIn, Input, Max),
        io_output := sampled(Out - PrevOut, Output, Max),
        scheduler_util := calc_sched_util(PrevSched, SchedWall),
        prev_io := {In, Out},
        prev_sched := SchedWall
    }.

%% `Samples` with `Sample` added, holding at most the newest `Max`.
-spec sampled(Sample, queue:queue(Sample), pos_integer()) -> queue:queue(Sample).
sampled(Sample, Samples, Max) ->
    Added = queue:in(Sample, Samples),
    case queue:len(Added) > Max of
        true -> queue:drop(Added);
        false -> Added
    end.

-spec sparkline_points([number()], number(), number()) -> binary().
sparkline_points([], _Width, _Height) ->
    ~"";
sparkline_points([_], Width, Height) ->
    iolist_to_binary(io_lib:format("0,~.1f ~.1f,~.1f", [Height / 2.0, float(Width), Height / 2.0]));
sparkline_points(Values, Width, Height) ->
    Min = lists:min(Values),
    Range =
        case lists:max(Values) - Min of
            Flat when Flat == 0 -> 1;
            Spread -> Spread
        end,
    Step = Width / (length(Values) - 1),
    iolist_to_binary(points(Values, 0, Step, Min, Range, Height)).

-spec points([number(), ...], non_neg_integer(), float(), number(), number(), number()) ->
    iolist().
points([Value | Rest], Index, Step, Min, Range, Height) ->
    Point = io_lib:format("~.1f,~.1f", [
        float(Index * Step), float(Height - ((Value - Min) / Range * Height))
    ]),
    case Rest of
        [] -> [Point];
        [_ | _] -> [Point, " " | points(Rest, Index + 1, Step, Min, Range, Height)]
    end.

%%----------------------------------------------------------------------
%% Kura
%%----------------------------------------------------------------------

%% Kura is not a dependency: it is looked for in the running node and called
%% only when it is there, so what it answers is checked before it is used.

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
                has_behaviour(M, kura_repo)
            ]
    end.

-spec kura_repo_info(module()) -> repo().
kura_repo_info(RepoMod) ->
    Config =
        case optional(kura_repo, config, [RepoMod]) of
            {ok, Answer} when is_map(Answer) -> Answer;
            _ -> #{}
        end,
    #{
        module => atom_to_binary(RepoMod),
        database => maps:get(database, Config, ~"unknown"),
        hostname => maps:get(hostname, Config, ~"localhost"),
        port => maps:get(port, Config, 5432),
        pool_size => maps:get(pool_size, Config, 10),
        pool => maps:get(pool, Config, RepoMod)
    }.

-spec kura_pool_stats(atom()) -> pool_stats().
kura_pool_stats(PoolName) ->
    case whereis(PoolName) of
        PoolPid when is_pid(PoolPid) ->
            pool_stats_from_pid(PoolPid, PoolName);
        _ ->
            #{status => ~"down", available => 0, checked_out => 0, queued => 0}
    end.

-spec kura_migration_status(module()) -> [migration()].
kura_migration_status(RepoMod) ->
    case optional(kura_migrator, status, [RepoMod]) of
        {ok, Status} when is_list(Status) ->
            [
                #{
                    version => integer_to_binary(Version),
                    module => atom_to_binary(Module),
                    status => atom_to_binary(State)
                }
             || {Version, Module, State} <- Status,
                is_integer(Version),
                is_atom(Module),
                is_atom(State)
            ];
        _ ->
            []
    end.

-spec kura_schemas(module()) -> [schema()].
kura_schemas(RepoMod) ->
    case application:get_application(RepoMod) of
        {ok, App} ->
            case application:get_key(App, modules) of
                {ok, Modules} when is_list(Modules) ->
                    [
                        schema_info(Module)
                     || Module <- lists:sort(Modules),
                        is_atom(Module),
                        has_behaviour(Module, kura_schema)
                    ];
                _ ->
                    []
            end;
        undefined ->
            []
    end.

%% Internal

%% Calls an optional dependency. `error` when it is not in the node, does not
%% export the function or fails.
-spec optional(module(), atom(), [term()]) -> {ok, term()} | error.
optional(Module, Function, Arguments) ->
    case
        code:ensure_loaded(Module) =:= {module, Module} andalso
            erlang:function_exported(Module, Function, length(Arguments))
    of
        true ->
            try
                {ok, erlang:apply(Module, Function, Arguments)}
            catch
                _:_ -> error
            end;
        false ->
            error
    end.

-spec process(pid(), [tuple()]) -> process().
process(Pid, Info) ->
    #{
        pid => format_pid(Pid),
        name => registered_name(Pid, Info),
        memory => counter(memory, Info),
        reductions => counter(reductions, Info),
        message_queue_len => counter(message_queue_len, Info),
        current_function => format_mfa(item(current_function, Info)),
        initial_call => format_mfa(item(initial_call, Info)),
        status => status(Info)
    }.

-spec registered_name(pid(), [tuple()]) -> binary().
registered_name(Pid, Info) ->
    case item(registered_name, Info) of
        Name when is_atom(Name), Name =/= undefined -> atom_to_binary(Name);
        _ -> format_pid(Pid)
    end.

-spec counter(atom(), [tuple()]) -> non_neg_integer().
counter(Item, Info) ->
    case item(Item, Info) of
        Count when is_integer(Count), Count >= 0 -> Count;
        _ -> 0
    end.

-spec status([tuple()]) -> binary().
status(Info) ->
    case item(status, Info) of
        Status when is_atom(Status) -> atom_to_binary(Status);
        _ -> ~"unknown"
    end.

%% One item of a `process_info/2` or `count_children/1` answer. What it holds
%% is narrowed by whoever asks.
-spec item(atom(), [tuple()]) -> term().
item(Item, Info) ->
    case lists:keyfind(Item, 1, Info) of
        {Item, Value} -> Value;
        _ -> undefined
    end.

-spec format_pid(pid()) -> binary().
format_pid(Pid) ->
    list_to_binary(pid_to_list(Pid)).

-spec format_port(port()) -> binary().
format_port(Port) ->
    list_to_binary(erlang:port_to_list(Port)).

-spec format_mfa(term()) -> binary().
format_mfa({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) ->
    iolist_to_binary(io_lib:format("~s:~s/~b", [M, F, A]));
format_mfa(_) ->
    ~"unknown".

-spec format_ets_id(ets:table()) -> binary().
format_ets_id(Table) when is_atom(Table) ->
    atom_to_binary(Table);
format_ets_id(Table) ->
    printed(Table).

-spec printed(term()) -> binary().
printed(Term) ->
    unicode_binary(io_lib:format("~0tp", [Term], [{chars_limit, 200}])).

%% Text from the node (an application description, a port name) as UTF-8. A
%% list that is not text is printed instead of failing the page it is on.
-spec unicode_binary(unicode:chardata()) -> binary().
unicode_binary(Text) ->
    case unicode:characters_to_binary(Text) of
        Binary when is_binary(Binary) -> Binary;
        {_, Readable, _Rest} -> Readable
    end.

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

-spec find_top_supervisor(atom()) -> pid() | undefined.
find_top_supervisor(AppName) ->
    case try_named_sup(AppName) of
        Pid when is_pid(Pid) -> Pid;
        undefined -> find_sup_via_master(AppName)
    end.

-spec try_named_sup(atom()) -> pid() | undefined.
try_named_sup(AppName) ->
    SupStr = atom_to_list(AppName) ++ "_sup",
    try list_to_existing_atom(SupStr) of
        SupName ->
            case whereis(SupName) of
                Pid when is_pid(Pid) -> Pid;
                _ -> undefined
            end
    catch
        error:badarg -> undefined
    end.

%% The application master is asked for the supervisor it started. Looking
%% for it among the linked processes means calling `which_children` on
%% processes that are not supervisors and never answer.
-spec find_sup_via_master(atom()) -> pid() | undefined.
find_sup_via_master(AppName) ->
    case application_controller:get_master(AppName) of
        Master when is_pid(Master) ->
            case application_master:get_child(Master) of
                {Supervisor, _Module} when is_pid(Supervisor) -> Supervisor;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

%% `which_children/1` exits when the supervisor is gone.
-spec children(pid()) ->
    {ok, [{term(), pid() | restarting | undefined, supervisor | worker, term()}]} | error.
children(Pid) ->
    try supervisor:which_children(Pid) of
        Children -> {ok, Children}
    catch
        _:_ -> error
    end.

-spec build_tree(pid()) -> [child()].
build_tree(Pid) ->
    case children(Pid) of
        {ok, Children} ->
            [child(Id, ChildPid, Type) || {Id, ChildPid, Type, _Modules} <- Children];
        error ->
            []
    end.

-spec child(term(), pid() | restarting | undefined, supervisor | worker) -> child().
child(Id, Pid, Type) when is_pid(Pid) ->
    Info =
        case erlang:process_info(Pid, [status, memory, message_queue_len, current_function]) of
            undefined -> [];
            Items -> Items
        end,
    #{
        type => Type,
        name => format_child_id(Id),
        pid => format_pid(Pid),
        status =>
            case Info of
                [] -> ~"dead";
                _ -> status(Info)
            end,
        memory => counter(memory, Info),
        message_queue_len => counter(message_queue_len, Info),
        current_function => format_mfa(item(current_function, Info)),
        children =>
            case Type of
                supervisor -> build_tree(Pid);
                worker -> []
            end
    };
child(Id, NotRunning, Type) ->
    #{
        type => Type,
        name => format_child_id(Id),
        pid => atom_to_binary(NotRunning),
        status =>
            case NotRunning of
                restarting -> ~"restarting";
                undefined -> ~"stopped"
            end,
        memory => 0,
        message_queue_len => 0,
        current_function => ~"\x{2014}",
        children => []
    }.

-spec format_child_id(term()) -> binary().
format_child_id(Id) when is_atom(Id) -> atom_to_binary(Id);
format_child_id(Id) -> nova_liveboard_redact:child_id(Id).

-spec scheduler_wall_time() -> wall_time().
scheduler_wall_time() ->
    case erlang:statistics(scheduler_wall_time) of
        undefined -> [];
        Schedulers -> lists:sort(Schedulers)
    end.

-spec calc_sched_util(wall_time(), wall_time()) -> [#{id := pos_integer(), util := float()}].
calc_sched_util([], _) ->
    [];
calc_sched_util(_, []) ->
    [];
calc_sched_util(Prev, Curr) ->
    Before = #{Id => {Active, Total} || {Id, Active, Total} <- Prev},
    [
        #{id => Id, util => utilisation(Active - Active0, Total - Total0)}
     || {Id, Active, Total} <- Curr,
        {Active0, Total0} <- [maps:get(Id, Before, undefined)]
    ].

-spec utilisation(integer(), integer()) -> float().
utilisation(_Active, 0) -> 0.0;
utilisation(Active, Total) -> Active / Total * 100.

-spec has_behaviour(module(), module()) -> boolean().
has_behaviour(Module, Behaviour) ->
    try Module:module_info(attributes) of
        Attributes when is_list(Attributes) ->
            lists:member(
                Behaviour,
                lists:append([
                    Behaviours
                 || {behaviour, Behaviours} <- Attributes, is_list(Behaviours)
                ])
            );
        _ ->
            false
    catch
        _:_ -> false
    end.

-spec schema_info(module()) -> schema().
schema_info(Mod) ->
    #{
        module => atom_to_binary(Mod),
        table =>
            case optional(Mod, table, []) of
                {ok, Table} -> Table;
                error -> ~"unknown"
            end,
        fields => [
            Field
         || Declared <- listed(Mod, fields, []), {ok, Field} <- [field_info(Declared)]
        ],
        associations => [
            Association
         || Declared <- listed(kura_schema, associations, [Mod]),
            {ok, Association} <- [assoc_info(Declared)]
        ],
        indexes => [
            Index
         || Declared <- listed(kura_schema, indexes, [Mod]), {ok, Index} <- [index_info(Declared)]
        ]
    }.

-spec listed(module(), atom(), [term()]) -> [term()].
listed(Module, Function, Arguments) ->
    case optional(Module, Function, Arguments) of
        {ok, List} when is_list(List) -> List;
        _ -> []
    end.

%% Kura's records grow at the end between versions, so only the leading
%% fields are relied on.
-spec field_info(term()) ->
    {ok, #{name := binary(), type := binary(), primary_key := term(), virtual := term()}} | error.
field_info(Field) when
    is_tuple(Field), tuple_size(Field) >= 8, element(1, Field) =:= kura_field
->
    case element(2, Field) of
        Name when is_atom(Name) ->
            {ok, #{
                name => atom_to_binary(Name),
                type => format_kura_type(element(3, Field)),
                primary_key => element(6, Field),
                virtual => element(8, Field)
            }};
        _ ->
            error
    end;
field_info(_) ->
    error.

-spec assoc_info(term()) -> {ok, #{name := binary(), type := binary(), schema := binary()}} | error.
assoc_info(Assoc) when is_tuple(Assoc), tuple_size(Assoc) >= 4, element(1, Assoc) =:= kura_assoc ->
    case {element(2, Assoc), element(3, Assoc), element(4, Assoc)} of
        {Name, Type, Schema} when is_atom(Name), is_atom(Type), is_atom(Schema) ->
            {ok, #{
                name => atom_to_binary(Name),
                type => atom_to_binary(Type),
                schema => atom_to_binary(Schema)
            }};
        _ ->
            error
    end;
assoc_info(_) ->
    error.

-spec index_info(term()) -> {ok, #{columns := [binary()], unique := term()}} | error.
index_info({Columns, Opts}) when is_list(Columns) ->
    {ok, #{
        columns => [atom_to_binary(Column) || Column <- Columns, is_atom(Column)],
        unique =>
            case Opts of
                #{unique := Unique} -> Unique;
                _ -> false
            end
    }};
index_info(_) ->
    error.

-spec format_kura_type(term()) -> binary().
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
format_kura_type({enum, Values}) when is_list(Values) ->
    Names = [atom_to_binary(Value) || Value <- Values, is_atom(Value)],
    iolist_to_binary([~"enum(", lists:join(~", ", Names), ~")"]);
format_kura_type({array, Inner}) ->
    iolist_to_binary([~"array(", format_kura_type(Inner), ~")"]);
format_kura_type({embed, Kind, Mod}) when is_atom(Kind), is_atom(Mod) ->
    iolist_to_binary([atom_to_binary(Kind), ~"(", atom_to_binary(Mod), ~")"]);
format_kura_type(Other) ->
    printed(Other).

%% Reads the state of a pgo pool: `{State, Queue, Codel}`.
-spec pool_stats_from_pid(pid(), atom()) -> pool_stats().
pool_stats_from_pid(PoolPid, PoolName) ->
    Unknown = #{status => ~"unknown", available => 0, checked_out => 0, queued => 0},
    try sys:get_state(PoolPid) of
        {State, Queue, Codel} when is_map(Codel) ->
            case {State, table_size(Queue)} of
                {ready, QueueSize} when is_integer(QueueSize), QueueSize >= 0 ->
                    #{
                        status => ~"ready",
                        available => QueueSize,
                        checked_out => max(0, pool_size_from_sup(PoolName) - QueueSize),
                        queued => 0,
                        delay => maps:get(delay, Codel, 0)
                    };
                {busy, QueueSize} when is_integer(QueueSize), QueueSize >= 0 ->
                    #{
                        status => ~"busy",
                        available => 0,
                        checked_out => pool_size_from_sup(PoolName),
                        queued => QueueSize,
                        delay => maps:get(delay, Codel, 0)
                    };
                _ ->
                    Unknown
            end;
        _ ->
            Unknown
    catch
        _:_ -> Unknown
    end.

%% The number of objects in the ETS table `Table`, when it is one.
-spec table_size(term()) -> non_neg_integer() | undefined.
table_size(Table) ->
    case [Known || Known <- ets:all(), Known =:= Table] of
        [Known] ->
            case ets:info(Known, size) of
                Size when is_integer(Size), Size >= 0 -> Size;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

-spec pool_size_from_sup(atom()) -> non_neg_integer().
pool_size_from_sup(PoolName) ->
    case try_named_sup(PoolName) of
        undefined ->
            0;
        SupPid ->
            case children(SupPid) of
                {ok, Children} ->
                    case [Pid || {pgo_connection_sup, Pid, _, _} <- Children, is_pid(Pid)] of
                        [ConnSup | _] -> active_children(ConnSup);
                        [] -> 0
                    end;
                error ->
                    0
            end
    end.

-spec active_children(pid()) -> non_neg_integer().
active_children(Supervisor) ->
    try supervisor:count_children(Supervisor) of
        Counts -> counter(active, Counts)
    catch
        _:_ -> 0
    end.
