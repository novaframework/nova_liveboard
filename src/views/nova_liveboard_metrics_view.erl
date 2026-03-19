-module(nova_liveboard_metrics_view).
-behaviour(arizona_view).
-compile({parse_transform, arizona_parse_transform}).

-export([mount/2, render/1, handle_info/2]).

mount(_Arg, _Req) ->
    case arizona_live:is_connected(self()) of
        true -> erlang:send_after(2000, self(), refresh);
        false -> ok
    end,
    Metrics = nova_liveboard_data:collect_metrics(undefined),
    Prefix = nova_liveboard:prefix(),
    Bindings = metrics_to_bindings(Metrics),
    Layout =
        {nova_liveboard_layout, render, main_content, #{
            active_page => ~"metrics",
            prefix => Prefix,
            ws_path => <<Prefix/binary, "/live">>
        }},
    arizona_view:new(?MODULE, Bindings, Layout).

render(Bindings) ->
    arizona_template:from_html(
        ~"""""
    <div id="{arizona_template:get_binding(id, Bindings)}">
        <p class="refresh-info">Auto-refreshes every 2s</p>

        <div class="metric-grid">
            <div class="metric-card">
                <div class="stat-label">Total Memory</div>
                <div class="metric-current">{arizona_template:get_binding(total_mem_val, Bindings)}</div>
                <svg class="sparkline" viewBox="0 0 200 40" preserveAspectRatio="none">
                    <polyline points="{arizona_template:get_binding(total_mem_pts, Bindings)}" />
                </svg>
            </div>
            <div class="metric-card">
                <div class="stat-label">Process Memory</div>
                <div class="metric-current">{arizona_template:get_binding(proc_mem_val, Bindings)}</div>
                <svg class="sparkline" viewBox="0 0 200 40" preserveAspectRatio="none">
                    <polyline points="{arizona_template:get_binding(proc_mem_pts, Bindings)}" />
                </svg>
            </div>
            <div class="metric-card">
                <div class="stat-label">Binary Memory</div>
                <div class="metric-current">{arizona_template:get_binding(bin_mem_val, Bindings)}</div>
                <svg class="sparkline" viewBox="0 0 200 40" preserveAspectRatio="none">
                    <polyline points="{arizona_template:get_binding(bin_mem_pts, Bindings)}" />
                </svg>
            </div>
            <div class="metric-card">
                <div class="stat-label">Process Count</div>
                <div class="metric-current">{arizona_template:get_binding(proc_count_val, Bindings)}</div>
                <svg class="sparkline" viewBox="0 0 200 40" preserveAspectRatio="none">
                    <polyline points="{arizona_template:get_binding(proc_count_pts, Bindings)}" />
                </svg>
            </div>
            <div class="metric-card">
                <div class="stat-label">Run Queue</div>
                <div class="metric-current">{arizona_template:get_binding(run_queue_val, Bindings)}</div>
                <svg class="sparkline" viewBox="0 0 200 40" preserveAspectRatio="none">
                    <polyline points="{arizona_template:get_binding(run_queue_pts, Bindings)}" />
                </svg>
            </div>
            <div class="metric-card">
                <div class="stat-label">IO Input/s</div>
                <div class="metric-current">{arizona_template:get_binding(io_in_val, Bindings)}</div>
                <svg class="sparkline" viewBox="0 0 200 40" preserveAspectRatio="none">
                    <polyline points="{arizona_template:get_binding(io_in_pts, Bindings)}" />
                </svg>
            </div>
            <div class="metric-card">
                <div class="stat-label">IO Output/s</div>
                <div class="metric-current">{arizona_template:get_binding(io_out_val, Bindings)}</div>
                <svg class="sparkline" viewBox="0 0 200 40" preserveAspectRatio="none">
                    <polyline points="{arizona_template:get_binding(io_out_pts, Bindings)}" />
                </svg>
            </div>
        </div>

        <div class="card">
            <div class="card-title">Scheduler Utilization</div>
            <div class="scheduler-bars">
                {arizona_template:render_list(fun(SchedEntry) ->
                    Id = maps:get(id, SchedEntry),
                    Util = maps:get(util, SchedEntry),
                    Pct = integer_to_binary(min(100, round(Util))),
                    Color = sched_color(Util),
                    arizona_template:from_html(~"""
                    <div class="sched-row">
                        <span class="sched-label mono">S{integer_to_binary(Id)}</span>
                        <div class="bar" style="flex:1">
                            <div class="bar-fill {Color}" style="width:{Pct}%"></div>
                        </div>
                        <span class="sched-pct mono">{Pct}%</span>
                    </div>
                    """)
                end, arizona_template:get_binding(sched_util, Bindings))}
            </div>
        </div>
    </div>
    """""
    ).

handle_info(refresh, View) ->
    erlang:send_after(2000, self(), refresh),
    State = arizona_view:get_state(View),
    OldMetrics = arizona_stateful:get_binding(metrics_state, State),
    NewMetrics = nova_liveboard_data:collect_metrics(OldMetrics),
    NewB = metrics_to_bindings(NewMetrics),
    lists:foldl(fun({K, V}, S) ->
        arizona_stateful:put_binding(K, V, S)
    end, State, maps:to_list(NewB)),
    UpdatedState = lists:foldl(fun({K, V}, S) ->
        arizona_stateful:put_binding(K, V, S)
    end, State, maps:to_list(NewB)),
    {[], arizona_view:update_state(UpdatedState, View)}.

%% Internal

metrics_to_bindings(Metrics) ->
    TotalMem = queue:to_list(maps:get(total_memory, Metrics)),
    ProcMem = queue:to_list(maps:get(process_memory, Metrics)),
    BinMem = queue:to_list(maps:get(binary_memory, Metrics)),
    ProcCount = queue:to_list(maps:get(process_count, Metrics)),
    RunQueue = queue:to_list(maps:get(run_queue, Metrics)),
    IoIn = queue:to_list(maps:get(io_input, Metrics)),
    IoOut = queue:to_list(maps:get(io_output, Metrics)),
    #{
        id => ~"metrics_view",
        metrics_state => Metrics,
        total_mem_val => nova_liveboard_data:format_bytes(last_val(TotalMem)),
        total_mem_pts => nova_liveboard_data:sparkline_points(TotalMem, 200, 40),
        proc_mem_val => nova_liveboard_data:format_bytes(last_val(ProcMem)),
        proc_mem_pts => nova_liveboard_data:sparkline_points(ProcMem, 200, 40),
        bin_mem_val => nova_liveboard_data:format_bytes(last_val(BinMem)),
        bin_mem_pts => nova_liveboard_data:sparkline_points(BinMem, 200, 40),
        proc_count_val => integer_to_binary(last_val(ProcCount)),
        proc_count_pts => nova_liveboard_data:sparkline_points(ProcCount, 200, 40),
        run_queue_val => integer_to_binary(last_val(RunQueue)),
        run_queue_pts => nova_liveboard_data:sparkline_points(RunQueue, 200, 40),
        io_in_val => nova_liveboard_data:format_bytes(last_val(IoIn)),
        io_in_pts => nova_liveboard_data:sparkline_points(IoIn, 200, 40),
        io_out_val => nova_liveboard_data:format_bytes(last_val(IoOut)),
        io_out_pts => nova_liveboard_data:sparkline_points(IoOut, 200, 40),
        sched_util => maps:get(scheduler_util, Metrics)
    }.

last_val([]) -> 0;
last_val(List) -> lists:last(List).

sched_color(Util) when Util > 80 -> ~"bar-fill-red";
sched_color(Util) when Util > 50 -> ~"bar-fill-amber";
sched_color(_) -> ~"bar-fill-blue".
