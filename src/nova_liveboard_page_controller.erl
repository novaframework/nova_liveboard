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
    Page = extract_page(Path),
    case Page of
        <<"processes">> -> {nova_liveboard_processes_view, undefined};
        <<"ets">> -> {nova_liveboard_ets_view, undefined};
        <<"applications">> -> {nova_liveboard_apps_view, undefined};
        <<"ports">> -> {nova_liveboard_ports_view, undefined};
        _ -> {nova_liveboard_system_view, undefined}
    end.

extract_page(Path) ->
    Parts = binary:split(Path, <<"/">>, [global, trim_all]),
    case lists:last(Parts) of
        <<"liveboard">> -> <<"system">>;
        Page -> Page
    end.
