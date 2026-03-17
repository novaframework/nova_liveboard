-module(nova_liveboard_ports_view).
-behaviour(arizona_view).
-compile({parse_transform, arizona_parse_transform}).

-export([mount/2, render/1, handle_info/2]).

mount(_Arg, Req) ->
    case arizona_live:is_connected(self()) of
        true -> erlang:send_after(3000, self(), refresh);
        false -> ok
    end,
    Ports = nova_liveboard_data:port_info(),
    Prefix = extract_prefix(arizona_request:get_path(Req)),
    Bindings = #{
        id => ~"ports_view",
        ports => Ports
    },
    Layout = {nova_liveboard_layout, render, main_content, #{
        active_page => ~"ports",
        prefix => Prefix,
        ws_path => <<Prefix/binary, "/live">>
    }},
    arizona_view:new(?MODULE, Bindings, Layout).

render(Bindings) ->
    Ports = arizona_template:get_binding(ports, Bindings),
    arizona_template:from_html(~"""
    <div id="{arizona_template:get_binding(id, Bindings)}">
        <p class="refresh-info">{integer_to_binary(length(Ports))} open ports &middot; Auto-refreshes every 3s</p>
        <div class="card">
            <table>
                <thead>
                    <tr>
                        <th>Port</th>
                        <th>Name</th>
                        <th>Connected</th>
                        <th class="text-right">Input</th>
                        <th class="text-right">Output</th>
                    </tr>
                </thead>
                <tbody>
                    {arizona_template:render_list(fun render_port_row/1, Ports)}
                </tbody>
            </table>
        </div>
    </div>
    """).

handle_info(refresh, View) ->
    erlang:send_after(3000, self(), refresh),
    Ports = nova_liveboard_data:port_info(),
    State = arizona_view:get_state(View),
    UpdatedState = arizona_stateful:put_binding(ports, Ports, State),
    {[], arizona_view:update_state(UpdatedState, View)}.

%% Internal

extract_prefix(Path) ->
    case binary:split(Path, <<"/">>, [global, trim_all]) of
        [Prefix | _] -> <<"/" , Prefix/binary>>;
        _ -> ~"/liveboard"
    end.

render_port_row(Port) ->
    arizona_template:from_html(~"""
    <tr>
        <td class="mono text-dim">{maps:get(id, Port)}</td>
        <td class="mono">{maps:get(name, Port)}</td>
        <td class="mono text-dim">{maps:get(connected, Port)}</td>
        <td class="text-right mono">{nova_liveboard_data:format_bytes(maps:get(input, Port))}</td>
        <td class="text-right mono">{nova_liveboard_data:format_bytes(maps:get(output, Port))}</td>
    </tr>
    """).
