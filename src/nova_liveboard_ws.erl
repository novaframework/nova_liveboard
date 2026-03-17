-module(nova_liveboard_ws).

-export([init/1, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-spec init(ControllerData :: map()) -> {ok, map()}.
init(ControllerData) ->
    Req = maps:get(req, ControllerData),
    PathParams = cowboy_req:parse_qs(Req),
    {~"path", LivePath} = proplists:lookup(~"path", PathParams),
    {~"qs", Qs} = proplists:lookup(~"qs", PathParams),
    LiveRequest = Req#{path => LivePath, qs => Qs},
    {view, ViewModule, MountArg, _} = view_resolver(LiveRequest),
    ArizonaReq = arizona_cowboy_request:new(LiveRequest),
    {ok, ControllerData#{
        view_module => ViewModule,
        mount_arg => MountArg,
        arizona_req => ArizonaReq
    }}.

-spec websocket_init(map()) -> {reply, list(), map()} | {ok, map()}.
websocket_init(ControllerData) ->
    #{view_module := ViewModule, mount_arg := MountArg, arizona_req := ArizonaReq} = ControllerData,
    {ok, LivePid} = arizona_live:start_link(ViewModule, MountArg, ArizonaReq, self()),
    {HierarchicalStructure, Diff} = arizona_live:initial_render(LivePid),
    View = arizona_live:get_view(LivePid),
    ViewState = arizona_view:get_state(View),
    ViewId = arizona_stateful:get_binding(id, ViewState),
    InitialPayload = json_encode(#{
        type => ~"initial_render",
        stateful_id => ViewId,
        structure => HierarchicalStructure
    }),
    CD = ControllerData#{live_pid => LivePid},
    case Diff of
        [] ->
            {reply, [{text, InitialPayload}], CD};
        _ ->
            DiffPayload = json_encode(#{
                type => ~"diff",
                stateful_id => ViewId,
                changes => Diff,
                structure => #{}
            }),
            self() ! {pending_frame, {text, DiffPayload}},
            {reply, [{text, InitialPayload}], CD}
    end.

-spec websocket_handle({text, binary()}, map()) -> {reply, {text, iodata()}, map()} | {ok, map()}.
websocket_handle({text, JSONBinary}, ControllerData) ->
    try
        Message = json:decode(JSONBinary),
        case maps:get(~"type", Message, undefined) of
            ~"event" ->
                handle_event(Message, ControllerData);
            ~"ping" ->
                Pong = json_encode(#{type => ~"pong"}),
                {reply, {text, Pong}, ControllerData};
            _ ->
                {ok, ControllerData}
        end
    catch
        _:_:_ ->
            ErrPayload = json_encode(#{type => ~"error", message => ~"Internal server error"}),
            {reply, {text, ErrPayload}, ControllerData}
    end.

-spec websocket_info(term(), map()) -> {reply, {text, iodata()}, map()} | {ok, map()}.
websocket_info(
    {actions_response, StatefulId, Diff, HierarchicalStructure, Actions}, ControllerData
) ->
    ActionFrames = [action_to_frame(A) || A <- Actions],
    DiffFrames = diff_frames(StatefulId, Diff, HierarchicalStructure),
    AllFrames = ActionFrames ++ DiffFrames,
    send_frames(AllFrames, ControllerData);
websocket_info({pending_frame, Frame}, ControllerData) ->
    {reply, Frame, ControllerData};
websocket_info(_Msg, ControllerData) ->
    {ok, ControllerData}.

-spec terminate(term(), cowboy_req:req(), map()) -> ok.
terminate(Reason, _Req, ControllerData) ->
    case maps:get(live_pid, ControllerData, undefined) of
        undefined -> ok;
        LivePid -> gen_server:stop(LivePid, {shutdown, Reason}, 5_000)
    end.

%% Internal

handle_event(Message, ControllerData) ->
    #{live_pid := LivePid} = ControllerData,
    StatefulIdOrUndefined = maps:get(~"stateful_id", Message, undefined),
    Event = maps:get(~"event", Message),
    Params = maps:get(~"params", Message, #{}),
    RefId = maps:get(~"ref_id", Message, undefined),
    Payload =
        case RefId of
            undefined -> Params;
            _ -> {RefId, Params}
        end,
    ok = arizona_live:handle_event(LivePid, StatefulIdOrUndefined, Event, Payload),
    {ok, ControllerData}.

view_resolver(#{path := Path}) ->
    Page = extract_page(Path),
    case Page of
        <<"processes">> -> {view, nova_liveboard_processes_view, undefined, []};
        <<"ets">> -> {view, nova_liveboard_ets_view, undefined, []};
        <<"applications">> -> {view, nova_liveboard_apps_view, undefined, []};
        <<"ports">> -> {view, nova_liveboard_ports_view, undefined, []};
        _ -> {view, nova_liveboard_system_view, undefined, []}
    end.

extract_page(Path) ->
    Parts = binary:split(Path, <<"/">>, [global, trim_all]),
    case lists:last(Parts) of
        <<"liveboard">> -> <<"system">>;
        Last -> Last
    end.

action_to_frame({dispatch, Event, Data}) ->
    {text, json_encode(#{type => ~"dispatch", event => Event, data => Data})};
action_to_frame({reply, Ref, Data}) ->
    {text, json_encode(#{type => ~"reply", ref_id => Ref, data => Data})};
action_to_frame({redirect, Url, Options}) ->
    {text, json_encode(#{type => ~"redirect", url => Url, options => Options})};
action_to_frame(reload) ->
    {text, json_encode(#{type => ~"reload"})}.

diff_frames(_StatefulId, [], _HierarchicalStructure) ->
    [];
diff_frames(StatefulId, Diff, HierarchicalStructure) ->
    [
        {text,
            json_encode(#{
                type => ~"diff",
                stateful_id => StatefulId,
                changes => Diff,
                structure => HierarchicalStructure
            })}
    ].

send_frames([], ControllerData) ->
    {ok, ControllerData};
send_frames([Frame], ControllerData) ->
    {reply, Frame, ControllerData};
send_frames([Frame | Rest], ControllerData) ->
    [self() ! {pending_frame, F} || F <- Rest],
    {reply, Frame, ControllerData}.

json_encode(Term) ->
    json:encode(Term, fun json_encoder/2).

json_encoder(Tuple, Encoder) when is_tuple(Tuple) ->
    json:encode_list(tuple_to_list(Tuple), Encoder);
json_encoder(Other, Encoder) ->
    json:encode_value(Other, Encoder).
