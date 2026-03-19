-module(nova_liveboard_database_view).
-behaviour(arizona_view).
-compile({parse_transform, arizona_parse_transform}).

-export([mount/2, render/1, handle_info/2]).

mount(_Arg, _Req) ->
    case arizona_live:is_connected(self()) of
        true -> erlang:send_after(5000, self(), refresh);
        false -> ok
    end,
    Repos = nova_liveboard_data:kura_repos(),
    RepoData = [build_repo_data(R) || R <- Repos],
    Prefix = nova_liveboard:prefix(),
    Bindings = #{
        id => ~"database_view",
        repos => RepoData
    },
    Layout =
        {nova_liveboard_layout, render, main_content, #{
            active_page => ~"database",
            prefix => Prefix,
            ws_path => <<Prefix/binary, "/live">>
        }},
    arizona_view:new(?MODULE, Bindings, Layout).

render(Bindings) ->
    Repos = arizona_template:get_binding(repos, Bindings),
    arizona_template:from_html(
        ~""""
    <div id="{arizona_template:get_binding(id, Bindings)}">
        <p class="refresh-info">Auto-refreshes every 5s</p>
        {arizona_template:render_list(fun(Repo) ->
            arizona_template:from_html(~"""
            <div class="card" style="margin-bottom:1.5rem">
                <div class="card-title">{maps:get(module, Repo)}</div>

                <div class="stat-grid">
                    <div class="stat">
                        <div class="stat-label">Database</div>
                        <div class="stat-value text-blue" style="font-size:1.1rem">{maps:get(database, Repo)}</div>
                        <div class="stat-sub">{maps:get(host_display, Repo)}</div>
                    </div>
                    <div class="stat">
                        <div class="stat-label">Pool Status</div>
                        <div class="stat-value {maps:get(status_class, Repo)}" style="font-size:1.1rem">{maps:get(pool_status, Repo)}</div>
                        <div class="stat-sub">size: {maps:get(pool_size_display, Repo)}</div>
                    </div>
                    <div class="stat">
                        <div class="stat-label">Available</div>
                        <div class="stat-value text-green">{maps:get(available_display, Repo)}</div>
                        <div class="bar" style="margin-top:0.5rem">
                            <div class="bar-fill bar-fill-green" style="width:{maps:get(available_pct, Repo)}%"></div>
                        </div>
                    </div>
                    <div class="stat">
                        <div class="stat-label">Checked Out</div>
                        <div class="stat-value text-amber">{maps:get(checked_out_display, Repo)}</div>
                        <div class="bar" style="margin-top:0.5rem">
                            <div class="bar-fill bar-fill-amber" style="width:{maps:get(checked_out_pct, Repo)}%"></div>
                        </div>
                    </div>
                </div>

                <div class="card-title" style="margin-top:1rem">Migrations ({maps:get(applied_display, Repo)} applied, {maps:get(pending_display, Repo)} pending)</div>
                {maps:get(migration_html, Repo)}
            </div>
            """)
        end, Repos)}
    </div>
    """"
    ).

handle_info(refresh, View) ->
    erlang:send_after(5000, self(), refresh),
    Repos = nova_liveboard_data:kura_repos(),
    RepoData = [build_repo_data(R) || R <- Repos],
    State = arizona_view:get_state(View),
    UpdatedState = arizona_stateful:put_binding(repos, RepoData, State),
    {[], arizona_view:update_state(UpdatedState, View)}.

%% Internal

build_repo_data(RepoMod) ->
    Info = nova_liveboard_data:kura_repo_info(RepoMod),
    Pool = maps:get(pool, Info),
    PoolStats = nova_liveboard_data:kura_pool_stats(Pool),
    Migrations = nova_liveboard_data:kura_migration_status(RepoMod),
    PoolSize = maps:get(pool_size, Info),
    Available = maps:get(available, PoolStats),
    CheckedOut = maps:get(checked_out, PoolStats),
    PendingCount = length([M || M <- Migrations, maps:get(status, M) =:= ~"pending"]),
    AppliedCount = length([M || M <- Migrations, maps:get(status, M) =:= ~"up"]),
    #{
        module => maps:get(module, Info),
        database => maps:get(database, Info),
        host_display => iolist_to_binary([
            maps:get(hostname, Info), ~":", integer_to_binary(maps:get(port, Info))
        ]),
        pool_status => maps:get(status, PoolStats),
        status_class => pool_status_class(maps:get(status, PoolStats)),
        pool_size_display => integer_to_binary(PoolSize),
        available_display => integer_to_binary(Available),
        available_pct => pool_pct(Available, PoolSize),
        checked_out_display => integer_to_binary(CheckedOut),
        checked_out_pct => pool_pct(CheckedOut, PoolSize),
        applied_display => integer_to_binary(AppliedCount),
        pending_display => integer_to_binary(PendingCount),
        migration_html => migration_table_html(Migrations)
    }.

migration_table_html([]) ->
    ~"<p class=\"text-dim\" style=\"font-size:0.875rem\">No migrations found</p>";
migration_table_html(Migrations) ->
    Header =
        <<"<table><thead><tr>", "<th>Version</th><th>Module</th><th>Status</th>",
            "</tr></thead><tbody>">>,
    Rows = [migration_row(M) || M <- Migrations],
    Footer = ~"</tbody></table>",
    iolist_to_binary([Header, Rows, Footer]).

migration_row(Mig) ->
    Badge =
        case maps:get(status, Mig) of
            ~"up" -> ~"<span class=\"badge badge-green\">up</span>";
            ~"pending" -> ~"<span class=\"badge badge-amber\">pending</span>";
            S -> S
        end,
    iolist_to_binary([
        ~"<tr><td class=\"mono\">",
        maps:get(version, Mig),
        ~"</td><td class=\"mono text-blue\">",
        maps:get(module, Mig),
        ~"</td><td>",
        Badge,
        ~"</td></tr>"
    ]).

pool_status_class(~"ready") -> ~"text-green";
pool_status_class(~"busy") -> ~"text-amber";
pool_status_class(_) -> ~"text-dim".

pool_pct(_, 0) -> ~"0";
pool_pct(Val, Total) -> integer_to_binary(min(100, (Val * 100) div Total)).
