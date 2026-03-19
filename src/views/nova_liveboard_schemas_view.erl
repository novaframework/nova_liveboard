-module(nova_liveboard_schemas_view).
-behaviour(arizona_view).
-compile({parse_transform, arizona_parse_transform}).

-export([mount/2, render/1, handle_info/2]).

mount(_Arg, _Req) ->
    Repos = nova_liveboard_data:kura_repos(),
    Schemas = lists:flatmap(
        fun(R) ->
            nova_liveboard_data:kura_schemas(R)
        end,
        Repos
    ),
    PreparedSchemas = [prepare_schema(S) || S <- Schemas],
    Prefix = nova_liveboard:prefix(),
    Bindings = #{
        id => ~"schemas_view",
        schemas => PreparedSchemas
    },
    Layout =
        {nova_liveboard_layout, render, main_content, #{
            active_page => ~"schemas",
            prefix => Prefix,
            ws_path => <<Prefix/binary, "/live">>
        }},
    arizona_view:new(?MODULE, Bindings, Layout).

render(Bindings) ->
    Schemas = arizona_template:get_binding(schemas, Bindings),
    arizona_template:from_html(
        ~""""
    <div id="{arizona_template:get_binding(id, Bindings)}">
        <p class="refresh-info">{integer_to_binary(length(Schemas))} schemas</p>
        {arizona_template:render_list(fun(Schema) ->
            arizona_template:from_html(~"""
            <div class="card" style="margin-bottom:1rem">
                <div style="display:flex;align-items:baseline;gap:0.75rem;margin-bottom:0.75rem">
                    <span class="mono text-blue" style="font-size:1rem;font-weight:700">{maps:get(module, Schema)}</span>
                    <span class="text-dim" style="font-size:0.875rem">{maps:get(table, Schema)}</span>
                </div>
                {maps:get(fields_html, Schema)}
                {maps:get(assocs_html, Schema)}
                {maps:get(indexes_html, Schema)}
            </div>
            """)
        end, Schemas)}
    </div>
    """"
    ).

handle_info(_Msg, View) ->
    {[], View}.

%% Internal

prepare_schema(Schema) ->
    #{
        module => maps:get(module, Schema),
        table => maps:get(table, Schema),
        fields_html => fields_html(maps:get(fields, Schema)),
        assocs_html => assocs_html(maps:get(associations, Schema)),
        indexes_html => indexes_html(maps:get(indexes, Schema))
    }.

fields_html([]) ->
    ~"";
fields_html(Fields) ->
    Header =
        <<"<table><thead><tr>", "<th>Field</th><th>Type</th><th>PK</th><th>Virtual</th>",
            "</tr></thead><tbody>">>,
    Rows = [field_row(F) || F <- Fields],
    Footer = ~"</tbody></table>",
    iolist_to_binary([Header, Rows, Footer]).

field_row(F) ->
    PK = bool_badge(maps:get(primary_key, F)),
    Virtual = bool_badge(maps:get(virtual, F)),
    iolist_to_binary([
        ~"<tr><td class=\"mono\">",
        maps:get(name, F),
        ~"</td><td class=\"mono text-dim\">",
        maps:get(type, F),
        ~"</td><td>",
        PK,
        ~"</td><td>",
        Virtual,
        ~"</td></tr>"
    ]).

assocs_html([]) ->
    ~"";
assocs_html(Assocs) ->
    Header =
        <<"<div class=\"card-title\" style=\"margin-top:1rem\">Associations</div>",
            "<table><thead><tr>", "<th>Name</th><th>Type</th><th>Schema</th>",
            "</tr></thead><tbody>">>,
    Rows = [assoc_row(A) || A <- Assocs],
    Footer = ~"</tbody></table>",
    iolist_to_binary([Header, Rows, Footer]).

assoc_row(A) ->
    iolist_to_binary([
        ~"<tr><td class=\"mono\">",
        maps:get(name, A),
        ~"</td><td><span class=\"badge badge-blue\">",
        maps:get(type, A),
        ~"</span></td><td class=\"mono text-blue\">",
        maps:get(schema, A),
        ~"</td></tr>"
    ]).

indexes_html([]) ->
    ~"";
indexes_html(Indexes) ->
    Header =
        <<"<div class=\"card-title\" style=\"margin-top:1rem\">Indexes</div>", "<table><thead><tr>",
            "<th>Columns</th><th>Unique</th>", "</tr></thead><tbody>">>,
    Rows = [index_row(I) || I <- Indexes],
    Footer = ~"</tbody></table>",
    iolist_to_binary([Header, Rows, Footer]).

index_row(I) ->
    Cols = iolist_to_binary(lists:join(~", ", maps:get(columns, I))),
    Unique = bool_badge(maps:get(unique, I)),
    iolist_to_binary([
        ~"<tr><td class=\"mono\">",
        Cols,
        ~"</td><td>",
        Unique,
        ~"</td></tr>"
    ]).

bool_badge(true) -> ~"<span class=\"badge badge-green\">yes</span>";
bool_badge(false) -> ~"".
