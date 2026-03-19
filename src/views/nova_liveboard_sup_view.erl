-module(nova_liveboard_sup_view).
-behaviour(arizona_view).
-compile({parse_transform, arizona_parse_transform}).

-export([mount/2, render/1, handle_event/3, handle_info/2]).

mount(_Arg, _Req) ->
    case arizona_live:is_connected(self()) of
        true -> erlang:send_after(5000, self(), refresh);
        false -> ok
    end,
    Apps = [Name || {Name, _, _} <- lists:sort(application:which_applications())],
    SelectedApp =
        case Apps of
            [First | _] -> First;
            [] -> undefined
        end,
    Tree = fetch_tree(SelectedApp),
    Prefix = nova_liveboard:prefix(),
    Bindings = #{
        id => ~"sup_view",
        apps => Apps,
        selected_app => SelectedApp,
        selected_app_name => atom_to_binary(SelectedApp),
        flat_tree => flatten_tree(Tree)
    },
    Layout =
        {nova_liveboard_layout, render, main_content, #{
            active_page => ~"supervisors",
            prefix => Prefix,
            ws_path => <<Prefix/binary, "/live">>
        }},
    arizona_view:new(?MODULE, Bindings, Layout).

render(Bindings) ->
    arizona_template:from_html(
        ~"""""
    <div id="{arizona_template:get_binding(id, Bindings)}">
        <p class="refresh-info">Auto-refreshes every 5s</p>

        <div class="app-selector">
            {arizona_template:render_list(fun(App) ->
                AppBin = atom_to_binary(App),
                BtnClass = case App =:= arizona_template:get_binding(selected_app, Bindings) of
                    true -> ~"app-btn active";
                    false -> ~"app-btn"
                end,
                OnClick = <<"arizona.pushEvent('select_app', {app: '", AppBin/binary, "'})">>,
                arizona_template:from_html(~"""
                <button class="{BtnClass}" onclick="{OnClick}">{AppBin}</button>
                """)
            end, arizona_template:get_binding(apps, Bindings))}
        </div>

        <div class="card">
            <div class="card-title">Supervision Tree — {arizona_template:get_binding(selected_app_name, Bindings)}</div>
            <div class="tree-flat">
                {arizona_template:render_list(fun(Node) ->
                    Name = maps:get(name, Node),
                    Pid = maps:get(pid, Node),
                    Type = maps:get(type, Node),
                    Memory = maps:get(memory, Node, 0),
                    MsgQ = maps:get(message_queue_len, Node, 0),
                    Status = maps:get(status, Node, ~"unknown"),
                    Depth = maps:get(depth, Node),
                    Indent = integer_to_binary(Depth * 24),
                    TypeBadge = type_badge(Type),
                    TypeLabel = type_label(Type),
                    MsgClass = case MsgQ > 100 of true -> ~"text-amber"; false -> ~"" end,
                    arizona_template:from_html(~"""
                    <div class="tree-row" style="padding-left:{Indent}px">
                        <span class="{TypeBadge}">{TypeLabel}</span>
                        <span class="mono">{Name}</span>
                        <span class="tree-meta">
                            <span class="mono text-dim">{Pid}</span>
                            <span class="mono">{nova_liveboard_data:format_bytes(Memory)}</span>
                            <span class="mono {MsgClass}">msgq: {integer_to_binary(MsgQ)}</span>
                            <span class="badge badge-green">{Status}</span>
                        </span>
                    </div>
                    """)
                end, arizona_template:get_binding(flat_tree, Bindings))}
            </div>
        </div>
    </div>
    """""
    ).

handle_event(~"select_app", Params, View) ->
    AppBin = maps:get(~"app", Params),
    App = binary_to_existing_atom(AppBin),
    Tree = fetch_tree(App),
    State = arizona_view:get_state(View),
    S1 = arizona_stateful:put_binding(selected_app, App, State),
    S2 = arizona_stateful:put_binding(selected_app_name, AppBin, S1),
    S3 = arizona_stateful:put_binding(flat_tree, flatten_tree(Tree), S2),
    {[], arizona_view:update_state(S3, View)}.

handle_info(refresh, View) ->
    erlang:send_after(5000, self(), refresh),
    State = arizona_view:get_state(View),
    App = arizona_stateful:get_binding(selected_app, State),
    Tree = fetch_tree(App),
    UpdatedState = arizona_stateful:put_binding(flat_tree, flatten_tree(Tree), State),
    {[], arizona_view:update_state(UpdatedState, View)}.

%% Internal

fetch_tree(undefined) ->
    [];
fetch_tree(App) ->
    case nova_liveboard_data:supervision_tree(App) of
        {ok, Tree} -> Tree;
        {error, _} -> []
    end.

flatten_tree(Nodes) ->
    lists:reverse(flatten_tree(Nodes, 0, [])).

flatten_tree([], _Depth, Acc) ->
    Acc;
flatten_tree([#{children := Children} = Node | Rest], Depth, Acc) ->
    FlatNode = Node#{depth => Depth},
    Acc1 = flatten_tree(Children, Depth + 1, [FlatNode | Acc]),
    flatten_tree(Rest, Depth, Acc1).

type_badge(supervisor) -> ~"badge badge-blue";
type_badge(_) -> ~"badge badge-green".

type_label(supervisor) -> ~"sup";
type_label(_) -> ~"worker".
