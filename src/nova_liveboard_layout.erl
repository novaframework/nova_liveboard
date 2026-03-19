-module(nova_liveboard_layout).
-compile({parse_transform, arizona_parse_transform}).

-export([render/1]).

-export([kura_nav/2]).

render(Bindings) ->
    arizona_template:from_html(
        ~"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Nova Liveboard</title>
        <link rel="stylesheet" href="{arizona_template:get_binding(prefix, Bindings)}/assets/css/liveboard.css" />
        <script type="module">
            import Arizona from '{arizona_template:get_binding(prefix, Bindings)}/assets/js/arizona.min.js';
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
                <a href="{arizona_template:get_binding(prefix, Bindings)}/supervisors" class="{nav_class(arizona_template:get_binding(active_page, Bindings), <<"supervisors">>)}">Supervisors</a>
                <a href="{arizona_template:get_binding(prefix, Bindings)}/metrics" class="{nav_class(arizona_template:get_binding(active_page, Bindings), <<"metrics">>)}">Metrics</a>
                {kura_nav(arizona_template:get_binding(prefix, Bindings), arizona_template:get_binding(active_page, Bindings))}
            </div>
        </nav>
        <main class="main">
            {arizona_template:render_slot(arizona_template:get_binding(main_content, Bindings))}
        </main>
    </body>
    </html>
    """
    ).

nav_class(Active, Page) when Active =:= Page -> ~"active";
nav_class(_, _) -> ~"".

kura_nav(Prefix, Active) ->
    case nova_liveboard_data:kura_available() of
        true ->
            arizona_template:from_html(
                ~"""
            <span class="nav-sep"></span>
            <a href="{Prefix}/database" class="{nav_class(Active, <<"database">>)}">Database</a>
            <a href="{Prefix}/schemas" class="{nav_class(Active, <<"schemas">>)}">Schemas</a>
            """
            );
        false ->
            arizona_template:from_html(
                ~"""
            <span></span>
            """
            )
    end.
