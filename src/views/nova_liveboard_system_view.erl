-module(nova_liveboard_system_view).
-behaviour(arizona_view).
-compile({parse_transform, arizona_parse_transform}).

-export([mount/2, render/1, handle_info/2]).

mount(_Arg, _Req) ->
    case arizona_live:is_connected(self()) of
        true -> erlang:send_after(2000, self(), refresh);
        false -> ok
    end,
    Info = nova_liveboard_data:system_info(),
    Prefix = nova_liveboard:prefix(),
    Bindings = #{
        id => ~"system_view",
        info => Info
    },
    Layout =
        {nova_liveboard_layout, render, main_content, #{
            active_page => ~"system",
            prefix => Prefix,
            ws_path => <<Prefix/binary, "/live">>
        }},
    arizona_view:new(?MODULE, Bindings, Layout).

render(Bindings) ->
    Info = arizona_template:get_binding(info, Bindings),
    Mem = maps:get(memory, Info),
    arizona_template:from_html(
        ~"""
    <div id="{arizona_template:get_binding(id, Bindings)}">
        <p class="refresh-info">Auto-refreshes every 2s</p>

        <div class="stat-grid">
            <div class="stat">
                <div class="stat-label">OTP Release</div>
                <div class="stat-value text-blue">{maps:get(otp_release, Info)}</div>
                <div class="stat-sub">ERTS {maps:get(erts_version, Info)}</div>
            </div>
            <div class="stat">
                <div class="stat-label">Uptime</div>
                <div class="stat-value">{nova_liveboard_data:format_uptime(maps:get(uptime, Info))}</div>
                <div class="stat-sub">{maps:get(system_architecture, Info)}</div>
            </div>
            <div class="stat">
                <div class="stat-label">Schedulers</div>
                <div class="stat-value">{integer_to_binary(maps:get(scheduler_online, Info))}</div>
                <div class="stat-sub">of {integer_to_binary(maps:get(scheduler_count, Info))} available</div>
            </div>
            <div class="stat">
                <div class="stat-label">Total Memory</div>
                <div class="stat-value">{nova_liveboard_data:format_bytes(maps:get(total, Mem))}</div>
            </div>
        </div>

        <div class="stat-grid">
            <div class="stat">
                <div class="stat-label">Processes</div>
                <div class="stat-value">{nova_liveboard_data:format_number(maps:get(process_count, Info))}</div>
                <div class="stat-sub">limit: {nova_liveboard_data:format_number(maps:get(process_limit, Info))}</div>
                <div class="bar" style="margin-top:0.5rem">
                    <div class="bar-fill bar-fill-blue" style="width:{usage_pct(maps:get(process_count, Info), maps:get(process_limit, Info))}%"></div>
                </div>
            </div>
            <div class="stat">
                <div class="stat-label">Atoms</div>
                <div class="stat-value">{nova_liveboard_data:format_number(maps:get(atom_count, Info))}</div>
                <div class="stat-sub">limit: {nova_liveboard_data:format_number(maps:get(atom_limit, Info))}</div>
                <div class="bar" style="margin-top:0.5rem">
                    <div class="bar-fill bar-fill-amber" style="width:{usage_pct(maps:get(atom_count, Info), maps:get(atom_limit, Info))}%"></div>
                </div>
            </div>
            <div class="stat">
                <div class="stat-label">Ports</div>
                <div class="stat-value">{nova_liveboard_data:format_number(maps:get(port_count, Info))}</div>
                <div class="stat-sub">limit: {nova_liveboard_data:format_number(maps:get(port_limit, Info))}</div>
                <div class="bar" style="margin-top:0.5rem">
                    <div class="bar-fill bar-fill-green" style="width:{usage_pct(maps:get(port_count, Info), maps:get(port_limit, Info))}%"></div>
                </div>
            </div>
            <div class="stat">
                <div class="stat-label">ETS Tables</div>
                <div class="stat-value">{integer_to_binary(maps:get(ets_count, Info))}</div>
            </div>
        </div>

        <div class="card">
            <div class="card-title">Memory Breakdown</div>
            <table>
                <thead>
                    <tr>
                        <th>Type</th>
                        <th class="text-right">Size</th>
                        <th class="text-right">% of Total</th>
                        <th style="width:30%">Usage</th>
                    </tr>
                </thead>
                <tbody>
                    {render_mem_row(~"Processes", maps:get(processes_used, Mem), maps:get(total, Mem))}
                    {render_mem_row(~"Binary", maps:get(binary, Mem), maps:get(total, Mem))}
                    {render_mem_row(~"Code", maps:get(code, Mem), maps:get(total, Mem))}
                    {render_mem_row(~"ETS", maps:get(ets, Mem), maps:get(total, Mem))}
                    {render_mem_row(~"Atom", maps:get(atom_used, Mem), maps:get(total, Mem))}
                    {render_mem_row(~"System", maps:get(system, Mem), maps:get(total, Mem))}
                </tbody>
            </table>
        </div>
    </div>
    """
    ).

handle_info(refresh, View) ->
    erlang:send_after(2000, self(), refresh),
    Info = nova_liveboard_data:system_info(),
    State = arizona_view:get_state(View),
    UpdatedState = arizona_stateful:put_binding(info, Info, State),
    {[], arizona_view:update_state(UpdatedState, View)}.

%% Internal

usage_pct(Used, Limit) when Limit > 0 ->
    Pct = (Used * 100) div Limit,
    integer_to_binary(min(100, Pct));
usage_pct(_, _) ->
    ~"0".

render_mem_row(Label, Value, Total) ->
    Pct =
        case Total of
            0 -> 0;
            _ -> (Value * 100) div Total
        end,
    Color =
        if
            Pct > 60 -> ~"bar-fill-red";
            Pct > 30 -> ~"bar-fill-amber";
            true -> ~"bar-fill-blue"
        end,
    arizona_template:from_html(
        ~"""
    <tr>
        <td>{Label}</td>
        <td class="text-right mono">{nova_liveboard_data:format_bytes(Value)}</td>
        <td class="text-right mono">{integer_to_binary(Pct)}%</td>
        <td>
            <div class="bar">
                <div class="bar-fill {Color}" style="width:{integer_to_binary(Pct)}%"></div>
            </div>
        </td>
    </tr>
    """
    ).
