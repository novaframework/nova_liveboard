-module(nova_liveboard_page_controller).
-moduledoc """
Nova controllers for the liveboard pages.

Each page server-renders the full mission-control shell (`nova_liveboard_html:
page/4`) with a first-paint snapshot, then a `data-init` stream takes over and
repaints the live region. `page_inner/2` is the single place that maps a page
to its data + HTML; both these controllers and `nova_liveboard_sse` call it, so
the first paint and the live patches always agree.
""".

-export([
    index/1,
    processes/1,
    ets/1,
    applications/1,
    ports/1,
    supervisors/1,
    metrics/1,
    requests/1,
    request_show/1,
    database/1,
    schemas/1,
    page_inner/2,
    page_atom/1,
    app_names/0,
    default_app/1
]).

-define(TOP_N, 50).

%% ---------------------------------------------------------------------------
%% controllers
%% ---------------------------------------------------------------------------

index(_Req) ->
    full(overview, stream_path(overview), page_inner(overview, undefined)).

ets(_Req) ->
    full(ets, stream_path(ets), page_inner(ets, undefined)).

applications(_Req) ->
    full(applications, stream_path(applications), page_inner(applications, undefined)).

ports(_Req) ->
    full(ports, stream_path(ports), page_inner(ports, undefined)).

metrics(_Req) ->
    full(metrics, stream_path(metrics), page_inner(metrics, undefined)).

database(_Req) ->
    full(database, stream_path(database), page_inner(database, undefined)).

schemas(_Req) ->
    full(schemas, stream_path(schemas), page_inner(schemas, undefined)).

requests(_Req) ->
    full(requests, stream_path(requests), page_inner(requests, undefined)).

processes(Req) ->
    Sort = sort_qs(Req),
    Stream = <<(stream_path(processes))/binary, "?sort=", (atom_to_binary(Sort))/binary>>,
    full(processes, Stream, page_inner(processes, Sort)).

supervisors(Req) ->
    App = app_qs(Req),
    Stream = <<(stream_path(supervisors))/binary, "?app=", (atom_to_binary(App))/binary>>,
    full(supervisors, Stream, page_inner(supervisors, App)).

request_show(Req) ->
    Id = maps:get(~"id", maps:get(bindings, Req, #{}), ~""),
    %% Static page (stream => none): a stored snapshot must not be overwritten.
    full(requests, none, nova_liveboard_html:request_detail_html(nova_liveboard_tracer:get(Id))).

%% ---------------------------------------------------------------------------
%% shared render dispatch
%% ---------------------------------------------------------------------------

-doc "Map a page to its freshly-gathered data, rendered to the live region inner.".
-spec page_inner(atom(), term()) -> iodata().
page_inner(overview, _) ->
    nova_liveboard_html:overview_html(nova_liveboard_data:system_info());
page_inner(processes, Sort) ->
    nova_liveboard_html:processes_html(nova_liveboard_data:top_processes(Sort, ?TOP_N), Sort);
page_inner(ets, _) ->
    nova_liveboard_html:ets_html(nova_liveboard_data:ets_tables());
page_inner(applications, _) ->
    nova_liveboard_html:apps_html(nova_liveboard_data:running_applications());
page_inner(ports, _) ->
    nova_liveboard_html:ports_html(nova_liveboard_data:port_info());
page_inner(supervisors, App) ->
    nova_liveboard_html:sup_tree_html(
        app_names(), App, nova_liveboard_data:supervision_tree(App)
    );
page_inner(metrics, _) ->
    nova_liveboard_html:metrics_html(nova_liveboard_data:collect_metrics(undefined));
page_inner(requests, _) ->
    nova_liveboard_html:requests_html(
        nova_liveboard_tracer:recent(), nova_liveboard_tracer:trace_state(), tracing_enabled()
    );
page_inner(database, _) ->
    nova_liveboard_html:database_html(kura_repos());
page_inner(schemas, _) ->
    nova_liveboard_html:schemas_html(kura_schemas()).

-doc "Binary page name (from a route binding) to its page atom.".
-spec page_atom(binary()) -> atom().
page_atom(~"overview") -> overview;
page_atom(~"ets") -> ets;
page_atom(~"applications") -> applications;
page_atom(~"ports") -> ports;
page_atom(~"metrics") -> metrics;
page_atom(~"database") -> database;
page_atom(~"schemas") -> schemas;
page_atom(_) -> overview.

-spec app_names() -> [atom()].
app_names() ->
    [A || {A, _, _} <- application:which_applications()].

-spec default_app([atom()]) -> atom().
default_app(Names) ->
    case application:get_env(nova, bootstrap_application) of
        {ok, App} -> App;
        _ -> first_user_app(Names)
    end.

%% ---------------------------------------------------------------------------
%% internal
%% ---------------------------------------------------------------------------

full(Active, Stream, Main) ->
    Vitals = nova_liveboard_html:vitals_html(nova_liveboard_data:system_info()),
    Body = nova_liveboard_html:page(Active, Stream, Vitals, Main),
    {status, 200, nova_liveboard_html:csp_headers(), iolist_to_binary(Body)}.

stream_path(Page) ->
    <<(nova_liveboard:prefix())/binary, "/sse/", (atom_to_binary(Page))/binary>>.

sort_qs(Req) ->
    case proplists:get_value(~"sort", cowboy_req:parse_qs(Req)) of
        ~"reductions" -> reductions;
        ~"message_queue_len" -> message_queue_len;
        _ -> memory
    end.

app_qs(Req) ->
    Names = app_names(),
    case proplists:get_value(~"app", cowboy_req:parse_qs(Req)) of
        undefined ->
            default_app(Names);
        Bin ->
            case lists:search(fun(A) -> atom_to_binary(A) =:= Bin end, Names) of
                {value, A} -> A;
                false -> default_app(Names)
            end
    end.

first_user_app(Names) ->
    System = [kernel, stdlib, sasl, nova, datastar, cowboy, ranch, crypto],
    case [A || A <- Names, not lists:member(A, System)] of
        [A | _] -> A;
        [] -> nova_liveboard
    end.

%% Tracing is "on" if the plugin is in Nova's config, or the tracer has already
%% captured something (covers runtime registration).
tracing_enabled() ->
    plugin_in_config() orelse safe_active().

plugin_in_config() ->
    lists:any(
        fun
            ({_Type, Mod, _Opts}) -> Mod =:= nova_liveboard_trace_plugin;
            (_) -> false
        end,
        application:get_env(nova, plugins, [])
    ).

safe_active() ->
    whereis(nova_liveboard_tracer) =/= undefined andalso nova_liveboard_tracer:active().

kura_repos() ->
    [nova_liveboard_data:kura_repo_info(R) || R <- nova_liveboard_data:kura_repos()].

kura_schemas() ->
    lists:append([nova_liveboard_data:kura_schemas(R) || R <- nova_liveboard_data:kura_repos()]).
