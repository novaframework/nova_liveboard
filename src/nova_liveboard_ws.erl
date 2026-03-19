-module(nova_liveboard_ws).

-export([init/1, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

%% Wraps arizona_nova_websocket, converting list-based replies
%% to single-frame replies that Nova's handle_ws expects.

-spec init(ControllerData :: map()) -> {ok, map()}.
init(ControllerData) ->
    arizona_nova_websocket:init(ControllerData#{view_resolver => fun view_resolver/1}).

-spec websocket_init(map()) -> {reply, term(), map()} | {ok, map()}.
websocket_init(ControllerData) ->
    flatten_reply(arizona_nova_websocket:websocket_init(ControllerData)).

-spec websocket_handle(term(), map()) -> {reply, term(), map()} | {ok, map()}.
websocket_handle({ping, _}, ControllerData) ->
    {ok, ControllerData};
websocket_handle({pong, _}, ControllerData) ->
    {ok, ControllerData};
websocket_handle(Frame, ControllerData) ->
    flatten_reply(arizona_nova_websocket:websocket_handle(Frame, ControllerData)).

-spec websocket_info(term(), map()) -> {reply, term(), map()} | {ok, map()}.
websocket_info({pending_frame, Frame}, ControllerData) ->
    {reply, Frame, ControllerData};
websocket_info({actions_response, _, _, _, _} = Msg, ControllerData) ->
    flatten_reply(arizona_nova_websocket:websocket_info(Msg, ControllerData));
websocket_info({pubsub_message, _, _} = Msg, ControllerData) ->
    flatten_reply(arizona_nova_websocket:websocket_info(Msg, ControllerData));
websocket_info(_Msg, ControllerData) ->
    {ok, ControllerData}.

-spec terminate(term(), cowboy_req:req(), map()) -> ok.
terminate(Reason, Req, ControllerData) ->
    arizona_nova_websocket:terminate(Reason, Req, ControllerData).

%% Internal

%% Nova's handle_ws expects {reply, SingleFrame, CD}, not {reply, [Frame], CD}.
flatten_reply({ok, CD}) ->
    {ok, CD};
flatten_reply({reply, {_Type, _Data} = Frame, CD}) ->
    {reply, Frame, CD};
flatten_reply({reply, [], CD}) ->
    {ok, CD};
flatten_reply({reply, [Frame], CD}) ->
    {reply, Frame, CD};
flatten_reply({reply, [Frame | Rest], CD}) ->
    [self() ! {pending_frame, F} || F <- Rest],
    {reply, Frame, CD}.

view_resolver(#{path := Path}) ->
    Page = extract_page(Path),
    case Page of
        <<"processes">> -> {view, nova_liveboard_processes_view, undefined, []};
        <<"ets">> -> {view, nova_liveboard_ets_view, undefined, []};
        <<"applications">> -> {view, nova_liveboard_apps_view, undefined, []};
        <<"ports">> -> {view, nova_liveboard_ports_view, undefined, []};
        <<"supervisors">> -> {view, nova_liveboard_sup_view, undefined, []};
        <<"metrics">> -> {view, nova_liveboard_metrics_view, undefined, []};
        _ -> {view, nova_liveboard_system_view, undefined, []}
    end.

extract_page(Path) ->
    Parts = binary:split(Path, <<"/">>, [global, trim_all]),
    case lists:last(Parts) of
        <<"liveboard">> -> <<"system">>;
        Last -> Last
    end.
