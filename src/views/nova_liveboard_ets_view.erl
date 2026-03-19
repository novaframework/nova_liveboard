-module(nova_liveboard_ets_view).
-behaviour(arizona_view).
-compile({parse_transform, arizona_parse_transform}).

-export([mount/2, render/1, handle_info/2]).

mount(_Arg, _Req) ->
    case arizona_live:is_connected(self()) of
        true -> erlang:send_after(3000, self(), refresh);
        false -> ok
    end,
    Tables = nova_liveboard_data:ets_tables(),
    Sorted = lists:sort(
        fun(A, B) -> maps:get(memory_bytes, A) >= maps:get(memory_bytes, B) end, Tables
    ),
    Prefix = nova_liveboard:prefix(),
    Bindings = #{
        id => ~"ets_view",
        tables => Sorted
    },
    Layout =
        {nova_liveboard_layout, render, main_content, #{
            active_page => ~"ets",
            prefix => Prefix,
            ws_path => <<Prefix/binary, "/live">>
        }},
    arizona_view:new(?MODULE, Bindings, Layout).

render(Bindings) ->
    Tables = arizona_template:get_binding(tables, Bindings),
    arizona_template:from_html(
        ~""""
    <div id="{arizona_template:get_binding(id, Bindings)}">
        <p class="refresh-info">{integer_to_binary(length(Tables))} tables &middot; Auto-refreshes every 3s</p>
        <div class="card">
            <table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Type</th>
                        <th>Protection</th>
                        <th class="text-right">Size</th>
                        <th class="text-right">Memory</th>
                        <th>Owner</th>
                    </tr>
                </thead>
                <tbody>
                    {arizona_template:render_list(fun(Table) ->
                        arizona_template:from_html(~"""
                        <tr>
                            <td class="mono">{maps:get(name, Table)}</td>
                            <td><span class="badge badge-blue">{maps:get(type, Table)}</span></td>
                            <td>{maps:get(protection, Table)}</td>
                            <td class="text-right mono">{nova_liveboard_data:format_number(maps:get(size, Table))}</td>
                            <td class="text-right mono">{nova_liveboard_data:format_bytes(maps:get(memory_bytes, Table))}</td>
                            <td class="mono text-dim">{maps:get(owner, Table)}</td>
                        </tr>
                        """)
                    end, Tables)}
                </tbody>
            </table>
        </div>
    </div>
    """"
    ).

handle_info(refresh, View) ->
    erlang:send_after(3000, self(), refresh),
    Tables = nova_liveboard_data:ets_tables(),
    Sorted = lists:sort(
        fun(A, B) -> maps:get(memory_bytes, A) >= maps:get(memory_bytes, B) end, Tables
    ),
    State = arizona_view:get_state(View),
    UpdatedState = arizona_stateful:put_binding(tables, Sorted, State),
    {[], arizona_view:update_state(UpdatedState, View)}.
