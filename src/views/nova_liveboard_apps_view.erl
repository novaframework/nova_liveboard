-module(nova_liveboard_apps_view).
-behaviour(arizona_view).
-compile({parse_transform, arizona_parse_transform}).

-export([mount/2, render/1, handle_info/2]).

mount(_Arg, _Req) ->
    case arizona_live:is_connected(self()) of
        true -> erlang:send_after(5000, self(), refresh);
        false -> ok
    end,
    Apps = nova_liveboard_data:running_applications(),
    Prefix = nova_liveboard:prefix(),
    Bindings = #{
        id => ~"apps_view",
        applications => Apps
    },
    Layout =
        {nova_liveboard_layout, render, main_content, #{
            active_page => ~"applications",
            prefix => Prefix,
            ws_path => <<Prefix/binary, "/live">>
        }},
    arizona_view:new(?MODULE, Bindings, Layout).

render(Bindings) ->
    Apps = arizona_template:get_binding(applications, Bindings),
    arizona_template:from_html(
        ~""""
    <div id="{arizona_template:get_binding(id, Bindings)}">
        <p class="refresh-info">{integer_to_binary(length(Apps))} running applications</p>
        <div class="card">
            <table>
                <thead>
                    <tr>
                        <th>Application</th>
                        <th>Version</th>
                        <th>Description</th>
                    </tr>
                </thead>
                <tbody>
                    {arizona_template:render_list(fun(App) ->
                        arizona_template:from_html(~"""
                        <tr>
                            <td class="mono text-blue">{maps:get(name, App)}</td>
                            <td class="mono">{maps:get(version, App)}</td>
                            <td class="text-dim">{maps:get(description, App)}</td>
                        </tr>
                        """)
                    end, Apps)}
                </tbody>
            </table>
        </div>
    </div>
    """"
    ).

handle_info(refresh, View) ->
    erlang:send_after(5000, self(), refresh),
    Apps = nova_liveboard_data:running_applications(),
    State = arizona_view:get_state(View),
    UpdatedState = arizona_stateful:put_binding(applications, Apps, State),
    {[], arizona_view:update_state(UpdatedState, View)}.
