-module(nova_liveboard_html).
-moduledoc """
Pure HTML rendering for the liveboard - "BEAM mission control".

Every function here takes already-gathered data (from `nova_liveboard_data`
and `nova_liveboard_tracer`) and returns `iodata()`. No process state, no
side effects beyond reading the static `nova_liveboard:prefix/0` config, so
the whole module is unit-testable in isolation.

`page/4` renders the full document shell (vitals deck + instrument nav +
main stage). The per-region functions (`vitals_html/1`, `overview_html/1`,
`processes_html/2`, ...) render the *inner* of a live region; the page
controller uses them for the first paint and `nova_liveboard_sse` re-emits
them as Datastar patches as the VM changes.
""".

-export([
    page/4,
    vitals_html/1,
    overview_html/1,
    metrics_html/1,
    processes_html/2,
    ets_html/1,
    apps_html/1,
    ports_html/1,
    sup_tree_html/3,
    requests_html/3,
    requests_toolbar_html/1,
    request_row/1,
    request_detail_html/1,
    database_html/1,
    schemas_html/1,
    csp_headers/0,
    html_escape/1
]).

-define(NAV, [
    {overview, ~"Overview", ~"\x{25C8}"},
    {processes, ~"Processes", ~"\x{2261}"},
    {metrics, ~"Metrics", ~"\x{2248}"},
    {requests, ~"Requests", ~"\x{21AF}"},
    {supervisors, ~"Supervisors", ~"\x{2638}"},
    {applications, ~"Applications", ~"\x{25A4}"},
    {ets, ~"ETS", ~"\x{229E}"},
    {ports, ~"Ports", ~"\x{21C4}"}
]).

%% ---------------------------------------------------------------------------
%% document shell
%% ---------------------------------------------------------------------------

-doc """
Full HTML document: head + vitals deck + nav + the main stage.

`StreamPath` is the SSE path the main region should subscribe to (so it
repaints live), or `none` for a static page (e.g. a request detail) that must
not be overwritten by a stream.
""".
-spec page(atom(), binary() | none, iodata(), iodata()) -> iodata().
page(Active, StreamPath, VitalsInner, MainInner) ->
    P = nova_liveboard:prefix(),
    [
        ~"<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\">",
        ~"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">",
        ~"<title>nova liveboard \x{00B7} ",
        page_title(Active),
        ~"</title><link rel=\"stylesheet\" href=\"",
        P,
        ~"/assets/css/app.css\">",
        ~"<script type=\"module\" src=\"",
        P,
        ~"/assets/js/datastar.js\"></script></head><body>",
        ~"<div id=\"deck\">",
        header_html(P, VitalsInner),
        ~"<div class=\"body\">",
        nav_html(P, Active),
        ~"<main class=\"stage\">",
        stage_inner(StreamPath, MainInner),
        ~"</main></div></div></body></html>"
    ].

stage_inner(none, MainInner) ->
    [~"<div id=\"page\" class=\"page\">", MainInner, ~"</div>"];
stage_inner(StreamPath, MainInner) ->
    [
        ~"<div data-init=\"@get('",
        StreamPath,
        ~"')\"><div id=\"page\" class=\"page\">",
        MainInner,
        ~"</div></div>"
    ].

header_html(P, VitalsInner) ->
    [
        ~"<header class=\"masthead\"><div class=\"brand\"><span class=\"nova\">\x{2726}</span>",
        ~"<span class=\"wordmark\">nova<b>liveboard</b></span>",
        ~"<span class=\"live\"><span class=\"pip\"></span>live</span></div>",
        %% data-init opens the always-on vitals stream; #vitals is patched inner.
        ~"<div data-init=\"@get('",
        P,
        ~"/sse/vitals')\"><div id=\"vitals\" class=\"vitals\">",
        VitalsInner,
        ~"</div></div></header>"
    ].

nav_html(P, Active) ->
    Items = [nav_item(P, Active, Page, Label, Glyph) || {Page, Label, Glyph} <- ?NAV],
    Kura =
        case nova_liveboard_data:kura_available() of
            true ->
                [
                    ~"<div class=\"nav-sep\">data</div>",
                    nav_item(P, Active, database, ~"Database", ~"\x{2317}"),
                    nav_item(P, Active, schemas, ~"Schemas", ~"\x{229F}")
                ];
            false ->
                []
        end,
    [~"<nav class=\"rail\">", Items, Kura, ~"</nav>"].

nav_item(P, Active, Page, Label, Glyph) ->
    Cls =
        case Page =:= Active of
            true -> ~"item active";
            false -> ~"item"
        end,
    [
        ~"<a class=\"",
        Cls,
        ~"\" href=\"",
        P,
        ~"/",
        nav_path(Page),
        ~"\"><span class=\"glyph\">",
        Glyph,
        ~"</span><span class=\"label\">",
        Label,
        ~"</span></a>"
    ].

nav_path(overview) -> ~"";
nav_path(Page) -> atom_to_binary(Page).

page_title(overview) -> ~"overview";
page_title(Page) -> atom_to_binary(Page).

%% ---------------------------------------------------------------------------
%% vitals deck (always-on header strip)
%% ---------------------------------------------------------------------------

-doc "The live header gauges: capacity vs limits + memory + uptime.".
-spec vitals_html(map()) -> iodata().
vitals_html(Sys) ->
    #{
        process_count := Procs,
        process_limit := ProcLimit,
        port_count := Ports,
        port_limit := PortLimit,
        atom_count := Atoms,
        atom_limit := AtomLimit,
        run_queue := RunQ,
        uptime := Uptime,
        memory := Mem
    } = Sys,
    Total = maps:get(total, Mem),
    [
        vital_gauge(~"processes", Procs, ProcLimit),
        vital_gauge(~"ports", Ports, PortLimit),
        vital_gauge(~"atoms", Atoms, AtomLimit),
        vital_stat(~"run queue", integer_to_binary(RunQ)),
        vital_stat(~"memory", nova_liveboard_data:format_bytes(Total)),
        vital_stat(~"uptime", nova_liveboard_data:format_uptime(Uptime))
    ].

vital_gauge(Label, Used, Limit) ->
    Pct = pct(Used, Limit),
    [
        ~"<div class=\"vital\"><div class=\"v-top\"><span class=\"v-label\">",
        Label,
        ~"</span><span class=\"v-val\">",
        nova_liveboard_data:format_number(Used),
        ~"<span class=\"v-lim\">/",
        nova_liveboard_data:format_number(Limit),
        ~"</span></span></div>",
        bar(Pct, util_class(Pct)),
        ~"</div>"
    ].

vital_stat(Label, Value) ->
    [
        ~"<div class=\"vital\"><div class=\"v-top\"><span class=\"v-label\">",
        Label,
        ~"</span></div><div class=\"v-big\">",
        Value,
        ~"</div></div>"
    ].

%% ---------------------------------------------------------------------------
%% overview
%% ---------------------------------------------------------------------------

-doc "System identity + memory breakdown + capacity panels.".
-spec overview_html(map()) -> iodata().
overview_html(Sys) ->
    #{
        otp_release := Otp,
        erts_version := Erts,
        system_architecture := Arch,
        scheduler_count := Scheds,
        scheduler_online := SchedsOn,
        ets_count := EtsCount,
        memory := Mem
    } = Sys,
    [
        ~"<div class=\"grid two\">",
        panel(
            ~"node",
            [
                kv(~"otp release", Otp),
                kv(~"erts", Erts),
                kv(~"architecture", Arch),
                kv(~"schedulers", [
                    integer_to_binary(SchedsOn), ~" / ", integer_to_binary(Scheds)
                ]),
                kv(~"ets tables", integer_to_binary(EtsCount))
            ]
        ),
        panel(~"memory", memory_bars(Mem)),
        ~"</div>"
    ].

memory_bars(Mem) ->
    Total = maps:get(total, Mem),
    Rows = [
        {~"processes", maps:get(processes, Mem)},
        {~"binary", maps:get(binary, Mem)},
        {~"ets", maps:get(ets, Mem)},
        {~"code", maps:get(code, Mem)},
        {~"atom", maps:get(atom, Mem)},
        {~"system", maps:get(system, Mem)}
    ],
    [
        [
            ~"<div class=\"mrow\"><div class=\"m-top\"><span class=\"m-label\">",
            Label,
            ~"</span><span class=\"m-val\">",
            nova_liveboard_data:format_bytes(Bytes),
            ~"</span></div>",
            bar(pct(Bytes, Total), ~"cool"),
            ~"</div>"
        ]
     || {Label, Bytes} <- Rows
    ].

%% ---------------------------------------------------------------------------
%% metrics (sparklines + scheduler bars)
%% ---------------------------------------------------------------------------

-doc "Live sparklines for memory/IO/run-queue + scheduler utilisation bars.".
-spec metrics_html(map()) -> iodata().
metrics_html(M) ->
    Spark = fun(Key, Label, Fmt) ->
        Vals = queue:to_list(maps:get(Key, M)),
        spark_card(Label, Fmt(last_val(Vals)), Vals)
    end,
    Bytes = fun nova_liveboard_data:format_bytes/1,
    Int = fun integer_to_binary/1,
    [
        ~"<div class=\"grid spark\">",
        Spark(total_memory, ~"total memory", Bytes),
        Spark(process_memory, ~"process memory", Bytes),
        Spark(binary_memory, ~"binary memory", Bytes),
        Spark(process_count, ~"processes", Int),
        Spark(run_queue, ~"run queue", Int),
        Spark(io_input, ~"io in / tick", Bytes),
        Spark(io_output, ~"io out / tick", Bytes),
        ~"</div>",
        panel(~"scheduler utilisation", sched_bars(maps:get(scheduler_util, M, [])))
    ].

spark_card(Label, Value, Vals) ->
    Pts = nova_liveboard_data:sparkline_points(Vals, 240, 48),
    [
        ~"<div class=\"card\"><div class=\"c-label\">",
        Label,
        ~"</div><div class=\"c-val\">",
        Value,
        ~"</div><svg class=\"spark-svg\" viewBox=\"0 0 240 48\" preserveAspectRatio=\"none\">",
        ~"<polyline points=\"",
        Pts,
        ~"\"/></svg></div>"
    ].

sched_bars([]) ->
    empty(~"collecting scheduler samples...");
sched_bars(Utils) ->
    [
        begin
            Pct = min(100, round(maps:get(util, U))),
            PctB = integer_to_binary(Pct),
            [
                ~"<div class=\"sched\"><span class=\"s-id\">S",
                integer_to_binary(maps:get(id, U)),
                ~"</span>",
                bar(Pct, util_class(Pct)),
                ~"<span class=\"s-pct\">",
                PctB,
                ~"%</span></div>"
            ]
        end
     || U <- Utils
    ].

%% ---------------------------------------------------------------------------
%% processes
%% ---------------------------------------------------------------------------

-doc "Top processes table, sorted by `SortBy`, with sort controls.".
-spec processes_html([map()], atom()) -> iodata().
processes_html(Procs, SortBy) ->
    [
        ~"<div class=\"toolbar\"><span class=\"t-label\">sort by</span>",
        sort_btn(SortBy, memory, ~"memory"),
        sort_btn(SortBy, reductions, ~"reductions"),
        sort_btn(SortBy, message_queue_len, ~"msg queue"),
        ~"</div>",
        table(
            [~"pid", ~"name", ~"memory", ~"reductions", ~"msgq", ~"current"],
            [
                [
                    cell_mono(maps:get(pid, Pr)),
                    cell(maps:get(name, Pr)),
                    cell_num(nova_liveboard_data:format_bytes(maps:get(memory, Pr))),
                    cell_num(nova_liveboard_data:format_number(maps:get(reductions, Pr))),
                    cell_num(integer_to_binary(maps:get(message_queue_len, Pr))),
                    cell_mono(maps:get(current_function, Pr))
                ]
             || Pr <- Procs
            ]
        )
    ].

sort_btn(Active, Key, Label) ->
    P = nova_liveboard:prefix(),
    Cls =
        case Active =:= Key of
            true -> ~"chip active";
            false -> ~"chip"
        end,
    %% A plain link so the single page stream reopens with the new sort, rather
    %% than stacking a second EventSource over the running one.
    [
        ~"<a class=\"",
        Cls,
        ~"\" href=\"",
        P,
        ~"/processes?sort=",
        atom_to_binary(Key),
        ~"\">",
        Label,
        ~"</a>"
    ].

%% ---------------------------------------------------------------------------
%% ets / applications / ports
%% ---------------------------------------------------------------------------

-doc "ETS tables table.".
-spec ets_html([map()]) -> iodata().
ets_html(Tables) ->
    table(
        [~"name", ~"id", ~"type", ~"protection", ~"size", ~"memory", ~"owner"],
        [
            [
                cell(maps:get(name, T)),
                cell_mono(maps:get(id, T)),
                cell(maps:get(type, T)),
                cell(maps:get(protection, T)),
                cell_num(nova_liveboard_data:format_number(maps:get(size, T))),
                cell_num(nova_liveboard_data:format_bytes(maps:get(memory_bytes, T))),
                cell_mono(maps:get(owner, T))
            ]
         || T <- Tables
        ]
    ).

-doc "Running applications table.".
-spec apps_html([map()]) -> iodata().
apps_html(Apps) ->
    table(
        [~"application", ~"version", ~"description"],
        [
            [
                cell_strong(maps:get(name, A)),
                cell_mono(maps:get(version, A)),
                cell(maps:get(description, A))
            ]
         || A <- Apps
        ]
    ).

-doc "Open ports table.".
-spec ports_html([map()]) -> iodata().
ports_html(Ports) ->
    table(
        [~"id", ~"name", ~"connected", ~"input", ~"output"],
        [
            [
                cell_mono(maps:get(id, Po)),
                cell(maps:get(name, Po)),
                cell_mono(maps:get(connected, Po)),
                cell_num(nova_liveboard_data:format_bytes(maps:get(input, Po))),
                cell_num(nova_liveboard_data:format_bytes(maps:get(output, Po)))
            ]
         || Po <- Ports
        ]
    ).

%% ---------------------------------------------------------------------------
%% supervision tree
%% ---------------------------------------------------------------------------

-doc "The supervision tree for `Active` (static process structure) + app chooser.".
-spec sup_tree_html([atom()], atom(), {ok, list()} | {error, term()}) -> iodata().
sup_tree_html(Apps, Active, Result) ->
    [
        ~"<div class=\"toolbar\"><span class=\"t-label\">application</span>",
        [app_chip(A, Active) || A <- lists:sort(Apps)],
        ~"</div>",
        sup_body(Active, Result)
    ].

app_chip(App, Active) ->
    P = nova_liveboard:prefix(),
    Name = atom_to_binary(App),
    Cls =
        case App =:= Active of
            true -> ~"chip active";
            false -> ~"chip"
        end,
    [
        ~"<a class=\"",
        Cls,
        ~"\" href=\"",
        P,
        ~"/supervisors?app=",
        Name,
        ~"\">",
        html_escape(Name),
        ~"</a>"
    ].

sup_body(_Active, {ok, Tree}) ->
    panel(~"supervision tree", [~"<div class=\"tree\">", tree_nodes(Tree, 0), ~"</div>"]);
sup_body(Active, {error, Reason}) ->
    empty([
        ~"no supervisor found for ",
        html_escape(atom_to_binary(Active)),
        ~" (",
        html_escape(to_bin(Reason)),
        ~")"
    ]).

tree_nodes(Nodes, Depth) ->
    [tree_node(N, Depth) || N <- Nodes].

tree_node(Node, Depth) ->
    #{type := Type, name := Name, pid := Pid, status := Status} = Node,
    Children = maps:get(children, Node, []),
    Mem = maps:get(memory, Node, 0),
    [
        ~"<div class=\"node\" style=\"--depth:",
        integer_to_binary(Depth),
        ~"\"><span class=\"n-kind ",
        kind_class(Type),
        ~"\">",
        kind_glyph(Type),
        ~"</span><span class=\"n-name\">",
        html_escape(Name),
        ~"</span><span class=\"n-pid\">",
        html_escape(Pid),
        ~"</span><span class=\"pip ",
        status_class(Status),
        ~"\"></span><span class=\"n-mem\">",
        nova_liveboard_data:format_bytes(Mem),
        ~"</span></div>",
        tree_nodes(Children, Depth + 1)
    ].

kind_glyph(supervisor) -> ~"\x{2638}";
kind_glyph(_) -> ~"\x{25CF}".

kind_class(supervisor) -> ~"sup";
kind_class(_) -> ~"worker".

%% ---------------------------------------------------------------------------
%% requests (the live request tracer feed)
%% ---------------------------------------------------------------------------

-doc """
The live request feed. `Enabled` reflects whether the tracing plugin is
registered; when it is not, a setup hint is shown instead of an empty feed.
`Trace` is the deep-trace arming state from `nova_liveboard_tracer`.
""".
-spec requests_html([map()], map(), boolean()) -> iodata().
requests_html(_Requests, _Trace, false) ->
    setup_hint();
requests_html(Requests, Trace, true) ->
    [
        ~"<div id=\"req-toolbar\" class=\"toolbar\">",
        requests_toolbar_html(Trace),
        ~"</div><div id=\"req-feed\" class=\"feed\">",
        case Requests of
            [] -> empty(~"no requests captured yet - hit any route on this node");
            _ -> [request_row(R) || R <- Requests]
        end,
        ~"</div>"
    ].

-doc "The arm/disarm/clear toolbar (patched on its own as trace state changes).".
-spec requests_toolbar_html(map()) -> iodata().
requests_toolbar_html(Trace) ->
    P = nova_liveboard:prefix(),
    Armed = maps:get(armed, Trace, false),
    Remaining = maps:get(remaining, Trace, 0),
    {StateCls, StateText} =
        case Armed of
            true ->
                {~"chip active", [
                    ~"deep trace armed \x{00B7} ", integer_to_binary(Remaining), ~" left"
                ]};
            false ->
                {~"chip", ~"deep trace off"}
        end,
    [
        ~"<span class=\"",
        StateCls,
        ~"\">",
        StateText,
        ~"</span>",
        ~"<button class=\"chip\" data-on-click=\"@post('",
        P,
        ~"/requests/trace/start')\">arm next 10</button>",
        ~"<button class=\"chip\" data-on-click=\"@post('",
        P,
        ~"/requests/trace/stop')\">disarm</button>",
        ~"<button class=\"chip danger\" data-on-click=\"@post('",
        P,
        ~"/requests/clear')\">clear</button>"
    ].

-doc "A single request row (also emitted as a prepended SSE patch on arrival).".
-spec request_row(map()) -> iodata().
request_row(R) ->
    #{
        id := Id,
        method := Method,
        path := Path,
        status := Status,
        duration_us := Dur,
        reductions := Reds,
        handler := Handler,
        spawned := Spawned
    } = R,
    P = nova_liveboard:prefix(),
    [
        ~"<a class=\"req\" href=\"",
        P,
        ~"/requests/",
        Id,
        ~"\"><span class=\"method ",
        method_class(Method),
        ~"\">",
        html_escape(Method),
        ~"</span><span class=\"r-path\">",
        html_escape(Path),
        ~"</span><span class=\"status ",
        status_code_class(Status),
        ~"\">",
        status_bin(Status),
        ~"</span><span class=\"r-dur\">",
        fmt_us(Dur),
        ~"</span><span class=\"r-reds\">",
        nova_liveboard_data:format_number(Reds),
        ~" reds</span><span class=\"r-spawn\">",
        spawn_badge(Spawned),
        ~"</span><span class=\"r-handler\">",
        html_escape(Handler),
        ~"</span></a>"
    ].

spawn_badge(N) when is_integer(N), N > 0 ->
    [~"\x{2387} ", integer_to_binary(N)];
spawn_badge(_) ->
    ~"\x{00B7}".

-doc "Detail page for one captured request: timings + spawned-process tree.".
-spec request_detail_html(map() | undefined) -> iodata().
request_detail_html(undefined) ->
    empty(~"request not found (the buffer may have rolled over)");
request_detail_html(R) ->
    #{
        method := Method,
        path := Path,
        status := Status,
        duration_us := Dur,
        reductions := Reds,
        mem := Mem,
        handler := Handler,
        spawned_tree := Tree
    } = R,
    [
        ~"<div class=\"req-head\"><span class=\"method ",
        method_class(Method),
        ~"\">",
        html_escape(Method),
        ~"</span><span class=\"rh-path\">",
        html_escape(Path),
        ~"</span></div>",
        ~"<div class=\"grid two\">",
        panel(~"timings", [
            kv(~"status", status_bin(Status)),
            kv(~"duration", fmt_us(Dur)),
            kv(~"reductions", nova_liveboard_data:format_number(Reds)),
            kv(~"peak memory", nova_liveboard_data:format_bytes(Mem)),
            kv(~"handler", html_escape(Handler))
        ]),
        panel(
            [~"spawned processes (", integer_to_binary(length(Tree)), ~")"],
            spawned_tree_html(Tree)
        ),
        ~"</div>"
    ].

spawned_tree_html([]) ->
    empty(~"no processes spawned during this request (or deep trace was off)");
spawned_tree_html(Tree) ->
    [
        ~"<div class=\"tree\">",
        [
            [
                ~"<div class=\"node\" style=\"--depth:",
                integer_to_binary(maps:get(depth, S, 0)),
                ~"\"><span class=\"n-kind worker\">\x{25CF}</span><span class=\"n-name\">",
                html_escape(maps:get(mfa, S)),
                ~"</span><span class=\"n-pid\">",
                html_escape(maps:get(pid, S)),
                ~"</span></div>"
            ]
         || S <- Tree
        ],
        ~"</div>"
    ].

setup_hint() ->
    [
        ~"<div class=\"hint\"><h2>request tracing is off</h2>",
        ~"<p>Add the liveboard tracing plugin to your Nova config to capture every ",
        ~"request handled by this node, then watch them stream in here live.</p>",
        ~"<pre class=\"code\">{nova, [\n",
        ~"  {plugins, [\n",
        ~"    {pre_request,  nova_liveboard_trace_plugin, #{}},\n",
        ~"    {post_request, nova_liveboard_trace_plugin, #{}}\n",
        ~"  ]}\n",
        ~"]}.</pre></div>"
    ].

%% ---------------------------------------------------------------------------
%% kura: database + schemas
%% ---------------------------------------------------------------------------

-doc "Kura repo pool panels.".
-spec database_html([map()]) -> iodata().
database_html([]) ->
    empty(~"no kura repos detected");
database_html(Repos) ->
    [
        ~"<div class=\"grid two\">",
        [
            panel(html_escape(maps:get(module, Repo)), [
                kv(~"database", html_escape(maps:get(database, Repo))),
                kv(~"host", [
                    html_escape(maps:get(hostname, Repo)), ~":", to_bin(maps:get(port, Repo))
                ]),
                kv(~"pool size", integer_to_binary(maps:get(pool_size, Repo))),
                pool_stat(maps:get(pool, Repo))
            ])
         || Repo <- Repos
        ],
        ~"</div>"
    ].

pool_stat(Stats) ->
    Status = maps:get(status, Stats, ~"unknown"),
    [
        ~"<div class=\"kv\"><span class=\"k\">pool</span><span class=\"v\"><span class=\"status ",
        pool_class(Status),
        ~"\">",
        html_escape(Status),
        ~"</span> avail ",
        integer_to_binary(maps:get(available, Stats, 0)),
        ~" \x{00B7} busy ",
        integer_to_binary(maps:get(checked_out, Stats, 0)),
        ~"</span></div>"
    ].

-doc "Kura schema definitions (fields, associations, indexes).".
-spec schemas_html([map()]) -> iodata().
schemas_html([]) ->
    empty(~"no kura schemas detected");
schemas_html(Schemas) ->
    [
        panel([html_escape(maps:get(module, S)), ~" \x{2192} ", html_escape(maps:get(table, S))], [
            table(
                [~"field", ~"type", ~"flags"],
                [
                    [
                        cell_strong(maps:get(name, F)),
                        cell_mono(maps:get(type, F)),
                        cell(field_flags(F))
                    ]
                 || F <- maps:get(fields, S)
                ]
            )
        ])
     || S <- Schemas
    ].

field_flags(F) ->
    PK =
        case maps:get(primary_key, F, false) of
            true -> [~"pk "];
            false -> []
        end,
    V =
        case maps:get(virtual, F, false) of
            true -> [~"virtual"];
            false -> []
        end,
    case [PK, V] of
        [[], []] -> ~"\x{00B7}";
        Flags -> Flags
    end.

%% ---------------------------------------------------------------------------
%% shared widgets
%% ---------------------------------------------------------------------------

panel(Title, Body) ->
    [
        ~"<section class=\"panel\"><h3 class=\"p-title\">",
        Title,
        ~"</h3><div class=\"p-body\">",
        Body,
        ~"</div></section>"
    ].

bar(Pct, Cls) ->
    PctB = integer_to_binary(min(100, max(0, Pct))),
    [
        ~"<div class=\"bar\"><span class=\"fill ",
        Cls,
        ~"\" style=\"width:",
        PctB,
        ~"%\"></span></div>"
    ].

table(Headers, Rows) ->
    [
        ~"<div class=\"table-wrap\"><table class=\"table\"><thead><tr>",
        [[~"<th>", H, ~"</th>"] || H <- Headers],
        ~"</tr></thead><tbody>",
        case Rows of
            [] ->
                [
                    ~"<tr><td class=\"empty-cell\" colspan=\"",
                    integer_to_binary(length(Headers)),
                    ~"\">nothing here</td></tr>"
                ];
            _ ->
                [[~"<tr>", Cells, ~"</tr>"] || Cells <- Rows]
        end,
        ~"</tbody></table></div>"
    ].

cell(V) -> [~"<td>", html_escape(V), ~"</td>"].
cell_strong(V) -> [~"<td class=\"strong\">", html_escape(V), ~"</td>"].
cell_mono(V) -> [~"<td class=\"mono\">", html_escape(V), ~"</td>"].
cell_num(V) -> [~"<td class=\"num\">", html_escape(V), ~"</td>"].

kv(K, V) ->
    [~"<div class=\"kv\"><span class=\"k\">", K, ~"</span><span class=\"v\">", V, ~"</span></div>"].

empty(Msg) ->
    [~"<p class=\"empty\">", html_escape(Msg), ~"</p>"].

%% ---------------------------------------------------------------------------
%% classification helpers
%% ---------------------------------------------------------------------------

util_class(P) when P >= 80 -> ~"hot";
util_class(P) when P >= 50 -> ~"warm";
util_class(_) -> ~"cool".

status_class(~"running") -> ~"ok";
status_class(~"waiting") -> ~"ok";
status_class(~"runnable") -> ~"warm";
status_class(~"restarting") -> ~"bad";
status_class(~"dead") -> ~"bad";
status_class(_) -> ~"idle".

status_code_class(S) when S >= 500 -> ~"s5";
status_code_class(S) when S >= 400 -> ~"s4";
status_code_class(S) when S >= 300 -> ~"s3";
status_code_class(_) -> ~"s2".

method_class(~"GET") -> ~"get";
method_class(~"POST") -> ~"post";
method_class(~"PUT") -> ~"put";
method_class(~"DELETE") -> ~"delete";
method_class(_) -> ~"other".

pool_class(~"ready") -> ~"s2";
pool_class(~"busy") -> ~"s4";
pool_class(~"down") -> ~"s5";
pool_class(_) -> ~"idle".

status_bin(undefined) -> ~"-";
status_bin(S) when is_integer(S) -> integer_to_binary(S);
status_bin(S) -> to_bin(S).

fmt_us(Us) when Us >= 1000000 ->
    iolist_to_binary(io_lib:format("~.2f s", [Us / 1000000]));
fmt_us(Us) when Us >= 1000 ->
    iolist_to_binary(io_lib:format("~.1f ms", [Us / 1000]));
fmt_us(Us) ->
    [integer_to_binary(Us), ~" \x{00B5}s"].

pct(_Used, 0) -> 0;
pct(Used, Limit) -> round(Used / Limit * 100).

last_val([]) -> 0;
last_val(L) -> lists:last(L).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

%% ---------------------------------------------------------------------------
%% security + escaping
%% ---------------------------------------------------------------------------

-doc """
The dashboard's response headers. Strict CSP: everything is same-origin
(self-hosted datastar.js, fonts, css), so any stray off-origin request fails
loudly. `unsafe-eval` is required only for Datastar's `data-*` expression
evaluation; the privacy-critical directives stay `'self'`.
""".
-spec csp_headers() -> map().
csp_headers() ->
    #{
        ~"content-type" => ~"text/html; charset=utf-8",
        ~"content-security-policy" =>
            ~"default-src 'self'; script-src 'self' 'unsafe-eval'; style-src 'self'; font-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'"
    }.

-doc "Escape `& < > \"` for safe interpolation into HTML.".
-spec html_escape(iodata() | atom() | integer()) -> binary().
html_escape(B) when is_binary(B) ->
    B1 = binary:replace(B, ~"&", ~"&amp;", [global]),
    B2 = binary:replace(B1, ~"<", ~"&lt;", [global]),
    B3 = binary:replace(B2, ~">", ~"&gt;", [global]),
    binary:replace(B3, ~"\"", ~"&quot;", [global]);
html_escape(V) ->
    html_escape(to_bin(V)).
