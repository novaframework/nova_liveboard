-module(nova_liveboard_page_controller).

-export([index/1]).

-spec index(Req :: map()) -> {status, integer(), map(), iodata()}.
index(CowboyReq) ->
    Path = cowboy_req:path(CowboyReq),
    {ViewModule, MountArg} = resolve_view(Path),
    ArizonaReq = arizona_cowboy_request:new(CowboyReq),
    try
        View = arizona_view:call_mount_callback(ViewModule, MountArg, ArizonaReq),
        {Html, _RenderView} = arizona_renderer:render_layout(View),
        {status, 200, #{<<"content-type">> => <<"text/html; charset=utf-8">>}, Html}
    catch
        Error:Reason:Stacktrace ->
            logger:error("Liveboard render error: ~p:~p~n~p", [Error, Reason, Stacktrace]),
            {status, 500, #{<<"content-type">> => <<"text/html">>}, <<"Internal Server Error">>}
    end.

resolve_view(Path) ->
    case page_from_path(Path) of
        <<"processes">> -> {nova_liveboard_processes_view, undefined};
        <<"ets">> -> {nova_liveboard_ets_view, undefined};
        <<"applications">> -> {nova_liveboard_apps_view, undefined};
        <<"ports">> -> {nova_liveboard_ports_view, undefined};
        <<"supervisors">> -> {nova_liveboard_sup_view, undefined};
        <<"metrics">> -> {nova_liveboard_metrics_view, undefined};
        _ -> {nova_liveboard_system_view, undefined}
    end.

page_from_path(Path) ->
    case binary:split(Path, <<"/">>, [global, trim_all]) of
        [] ->
            <<"system">>;
        Parts ->
            Last = lists:last(Parts),
            case view_for_page(Last) of
                true -> Last;
                false -> <<"system">>
            end
    end.

view_for_page(<<"processes">>) -> true;
view_for_page(<<"ets">>) -> true;
view_for_page(<<"applications">>) -> true;
view_for_page(<<"ports">>) -> true;
view_for_page(<<"supervisors">>) -> true;
view_for_page(<<"metrics">>) -> true;
view_for_page(_) -> false.
