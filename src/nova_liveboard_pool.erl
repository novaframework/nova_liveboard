-module(nova_liveboard_pool).
-moduledoc """
The connection pool of a Kura repo, as the Database page shows it.

Kura says which pool a repo uses and which module implements it
(`kura_db:get_pool/1` and `kura_db:get_pool_module/1`). Its pool behaviour has
no callback that reports figures, so those come from the library behind the
pool module, through one adapter per backend: a module with this behaviour
that calls only exported functions of that library.

| pool module | adapter | figures from |
| --- | --- | --- |
| `kura_pool_minato` | `nova_liveboard_pool_minato` | `minato:stats/1` |
| `kura_pool_sqlite` | `nova_liveboard_pool_sqlite` | nothing, it reports none |

A repo on any other pool module is shown with that module's name and no
figures.

`ask/1` starts reading a pool and `answer/2` collects it. The adapter runs in
a process of its own, and the answers of every repo are waited for until one
deadline, so pools that do not answer cost the page a second between them,
not a second each.
""".

-export([ask/1, answer/2, deadline/0]).

-define(ANSWER_MS, 1000).
-define(RUNNING, ~"running").
-define(NOT_STARTED, ~"not started").
-define(NOT_AVAILABLE, ~"not available").
-define(NO_ANSWER, ~"no answer").

-doc "What a pool holds now, and what it has counted since it started.".
-type figures() :: #{
    size := non_neg_integer(),
    in_use := non_neg_integer(),
    idle := non_neg_integer(),
    waiting := non_neg_integer(),
    counters := [{Label :: binary(), non_neg_integer()}]
}.

-doc "What an adapter answers: figures, no pool under that name, or why there are none.".
-type reading() :: {ok, figures()} | not_started | {not_available, Reason :: binary()}.

-doc """
A pool on the page. `status` is `running`, `not started`, `not available` or
`no answer`; `reason` says why there are no figures.
""".
-type pool() :: #{
    status := binary(),
    backend => binary(),
    name => binary(),
    figures => figures(),
    reason => binary()
}.

-opaque asked() ::
    {known, pool()} | {asked, binary(), binary(), nova_liveboard_optional:request()}.

-export_type([figures/0, reading/0, pool/0, asked/0]).

-doc "The name of the backend, as shown.".
-callback backend() -> binary().

-doc "The figures of the pool registered as `Pool`.".
-callback figures(Pool :: atom()) -> reading().

-doc "Starts reading the pool of `Repo`.".
-spec ask(module()) -> asked().
ask(Repo) ->
    case located(Repo) of
        {ok, PoolModule, Pool} ->
            Name = atom_to_binary(Pool),
            case adapter(PoolModule) of
                {ok, Adapter, Backend} ->
                    {asked, Backend, Name, nova_liveboard_optional:start(Adapter, figures, [Pool])};
                error ->
                    {known, #{
                        status => ?NOT_AVAILABLE,
                        backend => atom_to_binary(PoolModule),
                        name => Name,
                        reason => ~"the liveboard has no adapter for this pool module"
                    }}
            end;
        {error, Status, Reason} ->
            {known, #{status => Status, reason => Reason}}
    end.

-doc "The pool `ask/1` started reading, as far as it is known by `Deadline`.".
-spec answer(asked(), integer()) -> pool().
answer({known, Pool}, _Deadline) ->
    Pool;
answer({asked, Backend, Name, Request}, Deadline) ->
    case reading(nova_liveboard_optional:answer(Request, Deadline)) of
        {ok, Figures} ->
            #{status => ?RUNNING, backend => Backend, name => Name, figures => Figures};
        not_started ->
            #{
                status => ?NOT_STARTED,
                backend => Backend,
                name => Name,
                reason => ~"no pool is running under this name"
            };
        {not_available, Reason} ->
            #{status => ?NOT_AVAILABLE, backend => Backend, name => Name, reason => Reason};
        no_answer ->
            #{
                status => ?NO_ANSWER,
                backend => Backend,
                name => Name,
                reason => ~"the pool did not answer in time"
            }
    end.

-doc "The time by which pools asked now have to answer.".
-spec deadline() -> integer().
deadline() ->
    nova_liveboard_optional:deadline(?ANSWER_MS).

-spec adapter(module()) -> {ok, module(), binary()} | error.
adapter(kura_pool_minato) ->
    {ok, nova_liveboard_pool_minato, nova_liveboard_pool_minato:backend()};
adapter(kura_pool_sqlite) ->
    {ok, nova_liveboard_pool_sqlite, nova_liveboard_pool_sqlite:backend()};
adapter(_) ->
    error.

-spec located(module()) -> {ok, module(), atom()} | {error, binary(), binary()}.
located(Repo) ->
    case kura(get_pool, Repo) of
        {ok, Pool} ->
            case kura(get_pool_module, Repo) of
                {ok, PoolModule} -> {ok, PoolModule, Pool};
                {error, Status, Reason} -> {error, Status, Reason}
            end;
        {error, Status, Reason} ->
            {error, Status, Reason}
    end.

%% A reason Kura raises can repeat the repo's configuration, so only the
%% reasons Kura documents are told apart and nothing else of one is shown.
-spec kura(get_pool | get_pool_module, module()) -> {ok, atom()} | {error, binary(), binary()}.
kura(Function, Repo) ->
    case nova_liveboard_optional:call(kura_db, Function, [Repo]) of
        {ok, Answer} when is_atom(Answer) ->
            {ok, Answer};
        {ok, _} ->
            {error, ?NOT_AVAILABLE, ~"kura did not name the pool of the repo"};
        absent ->
            {error, ?NOT_AVAILABLE, ~"kura_db is not on this node"};
        missing ->
            {error, ?NOT_AVAILABLE,
                iolist_to_binary([
                    ~"kura_db:",
                    atom_to_binary(Function),
                    ~"/1 is not exported by the kura on this node"
                ])};
        {raised, error, {pool_not_started, Pool}} when is_atom(Pool) ->
            {error, ?NOT_STARTED,
                iolist_to_binary([~"kura did not start the pool ", atom_to_binary(Pool)])};
        {raised, error, {pool_owned_by, Owner}} when is_atom(Owner) ->
            {error, ?NOT_STARTED,
                iolist_to_binary([~"the pool belongs to the repo ", atom_to_binary(Owner)])};
        {raised, error, {no_pool_module_configured, _}} ->
            {error, ?NOT_AVAILABLE, ~"the repo has no pool module configured"};
        {raised, _, _} ->
            {error, ?NOT_AVAILABLE, ~"kura could not say which pool the repo uses"}
    end.

%% The adapter ran in another process, so its answer is checked again here.
-spec reading(nova_liveboard_optional:result() | timeout) -> reading() | no_answer.
reading(
    {ok,
        {ok, #{
            size := Size, in_use := InUse, idle := Idle, waiting := Waiting, counters := Counters
        }}}
) when
    is_integer(Size),
    Size >= 0,
    is_integer(InUse),
    InUse >= 0,
    is_integer(Idle),
    Idle >= 0,
    is_integer(Waiting),
    Waiting >= 0,
    is_list(Counters)
->
    {ok, #{
        size => Size,
        in_use => InUse,
        idle => Idle,
        waiting => Waiting,
        counters => [
            {Label, Count}
         || {Label, Count} <- Counters, is_binary(Label), is_integer(Count), Count >= 0
        ]
    }};
reading({ok, not_started}) ->
    not_started;
reading({ok, {not_available, Reason}}) when is_binary(Reason) ->
    {not_available, Reason};
reading(timeout) ->
    no_answer;
reading(_) ->
    {not_available, ~"reading the pool figures failed"}.
