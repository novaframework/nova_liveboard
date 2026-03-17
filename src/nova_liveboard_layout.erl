-module(nova_liveboard_layout).
-compile({parse_transform, arizona_parse_transform}).

-export([render/1]).

render(Bindings) ->
    arizona_template:from_html(~"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Nova Liveboard</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #e2e8f0; }
            .nav { background: #1e293b; border-bottom: 1px solid #334155; padding: 0 1.5rem; display: flex; align-items: center; gap: 2rem; height: 3.5rem; }
            .nav-brand { font-size: 1.1rem; font-weight: 700; color: #38bdf8; letter-spacing: -0.02em; }
            .nav-links { display: flex; gap: 0.25rem; }
            .nav-links a { padding: 0.5rem 1rem; color: #94a3b8; text-decoration: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; transition: all 0.15s; }
            .nav-links a:hover { color: #e2e8f0; background: #334155; }
            .nav-links a.active { color: #38bdf8; background: #0f172a; }
            .main { padding: 1.5rem; max-width: 90rem; margin: 0 auto; }
            .card { background: #1e293b; border: 1px solid #334155; border-radius: 0.5rem; padding: 1.25rem; margin-bottom: 1rem; }
            .card-title { font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: #64748b; margin-bottom: 0.75rem; }
            .stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(12rem, 1fr)); gap: 1rem; margin-bottom: 1.5rem; }
            .stat { background: #1e293b; border: 1px solid #334155; border-radius: 0.5rem; padding: 1rem; }
            .stat-label { font-size: 0.75rem; color: #64748b; text-transform: uppercase; letter-spacing: 0.05em; }
            .stat-value { font-size: 1.5rem; font-weight: 700; color: #f1f5f9; margin-top: 0.25rem; font-variant-numeric: tabular-nums; }
            .stat-sub { font-size: 0.75rem; color: #475569; margin-top: 0.125rem; }
            table { width: 100%; border-collapse: collapse; font-size: 0.875rem; }
            th { text-align: left; padding: 0.625rem 0.75rem; color: #64748b; font-weight: 600; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; border-bottom: 1px solid #334155; }
            td { padding: 0.5rem 0.75rem; border-bottom: 1px solid #1e293b; font-variant-numeric: tabular-nums; }
            tr:hover td { background: #1e293b; }
            .mono { font-family: "SF Mono", "Cascadia Code", "Fira Code", monospace; font-size: 0.8125rem; }
            .text-right { text-align: right; }
            .text-blue { color: #38bdf8; }
            .text-green { color: #4ade80; }
            .text-amber { color: #fbbf24; }
            .text-dim { color: #475569; }
            .bar { height: 0.375rem; background: #334155; border-radius: 9999px; overflow: hidden; }
            .bar-fill { height: 100%; border-radius: 9999px; transition: width 0.3s; }
            .bar-fill-blue { background: #38bdf8; }
            .bar-fill-green { background: #4ade80; }
            .bar-fill-amber { background: #fbbf24; }
            .bar-fill-red { background: #f87171; }
            .sort-btn { background: none; border: none; color: #64748b; cursor: pointer; font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; padding: 0.625rem 0.75rem; width: 100%; text-align: left; }
            .sort-btn:hover { color: #e2e8f0; }
            .sort-btn.active { color: #38bdf8; }
            .badge { display: inline-block; padding: 0.125rem 0.5rem; border-radius: 9999px; font-size: 0.75rem; font-weight: 500; }
            .badge-green { background: #166534; color: #4ade80; }
            .badge-blue { background: #1e3a5f; color: #38bdf8; }
            .refresh-info { font-size: 0.75rem; color: #475569; text-align: right; margin-bottom: 0.5rem; }
        </style>
        <script type="module">
            import Arizona from '/assets/js/arizona.min.js';
            globalThis.arizona = new Arizona();
            arizona.connect('{arizona_template:get_binding(ws_path, Bindings)}');
        </script>
    </head>
    <body>
        <nav class="nav">
            <span class="nav-brand">Nova Liveboard</span>
            <div class="nav-links">
                <a href="{arizona_template:get_binding(prefix, Bindings)}" class="{nav_class(arizona_template:get_binding(active_page, Bindings), <<"system">>)}">System</a>
                <a href="{arizona_template:get_binding(prefix, Bindings)}/processes" class="{nav_class(arizona_template:get_binding(active_page, Bindings), <<"processes">>)}">Processes</a>
                <a href="{arizona_template:get_binding(prefix, Bindings)}/ets" class="{nav_class(arizona_template:get_binding(active_page, Bindings), <<"ets">>)}">ETS</a>
                <a href="{arizona_template:get_binding(prefix, Bindings)}/applications" class="{nav_class(arizona_template:get_binding(active_page, Bindings), <<"applications">>)}">Applications</a>
                <a href="{arizona_template:get_binding(prefix, Bindings)}/ports" class="{nav_class(arizona_template:get_binding(active_page, Bindings), <<"ports">>)}">Ports</a>
            </div>
        </nav>
        <main class="main">
            {arizona_template:render_slot(arizona_template:get_binding(main_content, Bindings))}
        </main>
    </body>
    </html>
    """).

nav_class(Active, Page) when Active =:= Page -> ~"active";
nav_class(_, _) -> ~"".
