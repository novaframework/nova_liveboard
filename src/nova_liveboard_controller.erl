-module(nova_liveboard_controller).

-export([index/1, resolve_view/1]).

-spec index(Req :: map()) -> {status, integer(), map(), iodata()}.
index(CowboyReq) ->
    Path = cowboy_req:path(CowboyReq),
    {ViewModule, MountArg} = resolve_view_module(Path),
    ArizonaReq = arizona_cowboy_request:new(CowboyReq),
    try
        View = arizona_view:call_mount_callback(ViewModule, MountArg, ArizonaReq),
        {Html, _RenderView} = arizona_renderer:render_layout(View),
        {status, 200, #{<<"content-type">> => <<"text/html; charset=utf-8">>}, Html}
    catch
        Error:Reason:Stacktrace ->
            logger:error(~"Liveboard render error: ~p:~p~n~p", [Error, Reason, Stacktrace]),
            {status, 500, #{<<"content-type">> => <<"text/html">>}, <<"Internal Server Error">>}
    end.

-spec resolve_view(map()) -> {view, module(), term(), list()}.
resolve_view(#{path := Path}) ->
    {ViewModule, MountArg} = resolve_view_module(Path),
    {view, ViewModule, MountArg, []}.

resolve_view_module(Path) ->
    case page_from_path(Path) of
        <<"processes">> -> {nova_liveboard_processes_view, undefined};
        <<"ets">> -> {nova_liveboard_ets_view, undefined};
        <<"applications">> -> {nova_liveboard_apps_view, undefined};
        <<"ports">> -> {nova_liveboard_ports_view, undefined};
        <<"supervisors">> -> {nova_liveboard_sup_view, undefined};
        <<"metrics">> -> {nova_liveboard_metrics_view, undefined};
        <<"database">> -> {nova_liveboard_database_view, undefined};
        <<"schemas">> -> {nova_liveboard_schemas_view, undefined};
        _ -> {nova_liveboard_system_view, undefined}
    end.

page_from_path(Path) ->
    Pages = [
        <<"processes">>,
        <<"ets">>,
        <<"applications">>,
        <<"ports">>,
        <<"supervisors">>,
        <<"metrics">>,
        <<"database">>,
        <<"schemas">>
    ],
    case binary:split(Path, <<"/">>, [global, trim_all]) of
        [] ->
            <<"system">>;
        Parts ->
            Last = lists:last(Parts),
            case lists:member(Last, Pages) of
                true -> Last;
                false -> <<"system">>
            end
    end.
