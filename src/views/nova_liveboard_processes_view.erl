-module(nova_liveboard_processes_view).
-behaviour(arizona_view).
-compile({parse_transform, arizona_parse_transform}).

-export([mount/2, render/1, handle_event/3, handle_info/2]).

mount(_Arg, Req) ->
    case arizona_live:is_connected(self()) of
        true -> erlang:send_after(2000, self(), refresh);
        false -> ok
    end,
    SortBy = memory,
    Procs = nova_liveboard_data:top_processes(SortBy, 50),
    Prefix = extract_prefix(arizona_request:get_path(Req)),
    Bindings = #{
        id => ~"processes_view",
        processes => Procs,
        sort_by => SortBy
    },
    Layout = {nova_liveboard_layout, render, main_content, #{
        active_page => ~"processes",
        prefix => Prefix,
        ws_path => <<Prefix/binary, "/live">>
    }},
    arizona_view:new(?MODULE, Bindings, Layout).

render(Bindings) ->
    Procs = arizona_template:get_binding(processes, Bindings),
    SortBy = arizona_template:get_binding(sort_by, Bindings),
    arizona_template:from_html(~"""
    <div id="{arizona_template:get_binding(id, Bindings)}">
        <p class="refresh-info">Top 50 processes &middot; Auto-refreshes every 2s</p>
        <div class="card">
            <table>
                <thead>
                    <tr>
                        <th>PID</th>
                        <th>Name / Registered</th>
                        <th>Current Function</th>
                        <th class="text-right">
                            <button class="sort-btn {sort_class(SortBy, memory)}"
                                    data-event="sort" data-params-by="memory">Memory</button>
                        </th>
                        <th class="text-right">
                            <button class="sort-btn {sort_class(SortBy, reductions)}"
                                    data-event="sort" data-params-by="reductions">Reductions</button>
                        </th>
                        <th class="text-right">
                            <button class="sort-btn {sort_class(SortBy, message_queue_len)}"
                                    data-event="sort" data-params-by="msgq">Msg Queue</button>
                        </th>
                        <th>Status</th>
                    </tr>
                </thead>
                <tbody>
                    {arizona_template:render_list(fun render_proc_row/1, Procs)}
                </tbody>
            </table>
        </div>
    </div>
    """).

handle_event(~"sort", Params, View) ->
    SortBy = case maps:get(~"by", Params) of
        ~"memory" -> memory;
        ~"reductions" -> reductions;
        ~"msgq" -> message_queue_len;
        _ -> memory
    end,
    Procs = nova_liveboard_data:top_processes(SortBy, 50),
    State = arizona_view:get_state(View),
    S1 = arizona_stateful:put_binding(sort_by, SortBy, State),
    S2 = arizona_stateful:put_binding(processes, Procs, S1),
    {[], arizona_view:update_state(S2, View)}.

handle_info(refresh, View) ->
    erlang:send_after(2000, self(), refresh),
    State = arizona_view:get_state(View),
    SortBy = arizona_stateful:get_binding(sort_by, State),
    Procs = nova_liveboard_data:top_processes(SortBy, 50),
    UpdatedState = arizona_stateful:put_binding(processes, Procs, State),
    {[], arizona_view:update_state(UpdatedState, View)}.

%% Internal

extract_prefix(Path) ->
    case binary:split(Path, <<"/">>, [global, trim_all]) of
        [Prefix | _] -> <<"/" , Prefix/binary>>;
        _ -> ~"/liveboard"
    end.

sort_class(Current, Col) when Current =:= Col -> ~"active";
sort_class(_, _) -> ~"".

render_proc_row(Proc) ->
    Mem = maps:get(memory, Proc),
    MsgQ = maps:get(message_queue_len, Proc),
    MsgClass = if MsgQ > 100 -> ~"text-amber"; true -> ~"" end,
    arizona_template:from_html(~"""
    <tr>
        <td class="mono text-dim">{maps:get(pid, Proc)}</td>
        <td class="mono">{maps:get(name, Proc)}</td>
        <td class="mono text-dim">{maps:get(current_function, Proc)}</td>
        <td class="text-right mono">{nova_liveboard_data:format_bytes(Mem)}</td>
        <td class="text-right mono">{nova_liveboard_data:format_number(maps:get(reductions, Proc))}</td>
        <td class="text-right mono {MsgClass}">{integer_to_binary(MsgQ)}</td>
        <td><span class="badge badge-green">{maps:get(status, Proc)}</span></td>
    </tr>
    """).
