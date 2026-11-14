-module(nova_liveboard_test_server).
-moduledoc """
Boots a real Nova listener with the liveboard mounted into a minimal host app,
so tests can send raw HTTP over a socket.
""".

-export([
    start/1, start/2, stop/1, request/2, request/3, open/2, read/2, status/1, header/2, body/1
]).

-define(HOST_APP, nova_liveboard_test_host).

-type response() :: {pos_integer(), [{binary(), binary()}], binary()}.
-export_type([response/0]).

-spec start([{atom(), term()}]) -> #{port := inet:port_number(), env := [atom()], level := term()}.
start(BoardEnv) ->
    start(BoardEnv, #{}).

-doc "As `start/1`, with extra Cowboy protocol options for the listener.".
-spec start([{atom(), term()}], map()) ->
    #{port := inet:port_number(), env := [atom()], level := term()}.
start(BoardEnv, ProtocolOptions) ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, critical),
    Port = free_port(),
    _ = application:load(nova_liveboard),
    [application:set_env(nova_liveboard, Key, Value) || {Key, Value} <- BoardEnv],
    application:set_env(nova, bootstrap_application, ?HOST_APP),
    application:set_env(nova, cowboy_configuration, #{
        port => Port, ip => {127, 0, 0, 1}, options => ProtocolOptions#{compress => true}
    }),
    application:set_env(?HOST_APP, nova_apps, [nova_liveboard]),
    State = #{port => Port, env => [Key || {Key, _} <- BoardEnv], level => Level},
    case application:ensure_all_started(nova_liveboard) of
        {ok, _} ->
            State;
        {error, Reason} ->
            stop(State),
            error({nova_did_not_start, Reason})
    end.

-spec stop(map()) -> ok.
stop(#{env := Keys, level := Level}) ->
    _ = application:stop(nova_liveboard),
    _ = application:stop(nova),
    _ = application:stop(cowboy),
    _ = application:stop(ranch),
    %% Nova keeps its routing table in persistent_term and merges into it on
    %% the next start, first route wins: without this a later fixture would
    %% be served by the routes of an earlier one.
    _ = persistent_term:erase(nova_dispatch),
    _ = persistent_term:erase(nova_apps),
    [application:unset_env(nova_liveboard, Key) || Key <- Keys],
    application:unset_env(nova, bootstrap_application),
    application:unset_env(nova, cowboy_configuration),
    application:unset_env(?HOST_APP, nova_apps),
    ok = logger:set_primary_config(level, Level).

-doc "Send one request line plus headers verbatim and read the whole response.".
-spec request(map(), iodata()) -> response().
request(Server, RequestLine) ->
    request(Server, RequestLine, []).

-spec request(map(), iodata(), [{iodata(), iodata()}]) -> response().
request(Server, RequestLine, Headers) ->
    Socket = open(Server, [
        RequestLine, ~"\r\n", header_lines(Headers), ~"connection: close\r\n\r\n"
    ]),
    Raw = read_until_closed(Socket, <<>>),
    ok = gen_tcp:close(Socket),
    parse(Raw).

-doc "Send raw bytes and leave the socket open, for streaming responses.".
-spec open(map(), iodata()) -> gen_tcp:socket().
open(#{port := Port}, Bytes) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, Bytes),
    Socket.

-doc "Everything the socket delivers within `Timeout` ms (or until it closes).".
-spec read(gen_tcp:socket(), non_neg_integer()) -> {open | closed, binary()}.
read(Socket, Timeout) ->
    read(Socket, erlang:monotonic_time(millisecond) + Timeout, <<>>).

-spec status(response()) -> pos_integer().
status({Status, _Headers, _Body}) -> Status.

-spec header(binary(), response()) -> binary() | undefined.
header(Name, {_Status, Headers, _Body}) ->
    case lists:keyfind(Name, 1, Headers) of
        {Name, Value} when is_binary(Value) -> Value;
        _ -> undefined
    end.

-spec body(response()) -> binary().
body({_Status, _Headers, Body}) -> Body.

-spec read(gen_tcp:socket(), integer(), binary()) -> {open | closed, binary()}.
read(Socket, Deadline, Acc) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 ->
            case gen_tcp:recv(Socket, 0, Left) of
                {ok, Data} when is_binary(Data) ->
                    read(Socket, Deadline, <<Acc/binary, Data/binary>>);
                {error, timeout} ->
                    {open, Acc};
                _Closed ->
                    {closed, Acc}
            end;
        _ ->
            {open, Acc}
    end.

read_until_closed(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} when is_binary(Data) -> read_until_closed(Socket, <<Acc/binary, Data/binary>>);
        _ -> Acc
    end.

header_lines(Headers) ->
    [~"host: board.test\r\n" | [[Name, ~": ", Value, ~"\r\n"] || {Name, Value} <- Headers]].

parse(Raw) ->
    {ok, {http_response, _Version, Status, _Reason}, Rest} =
        erlang:decode_packet(http_bin, Raw, []),
    parse_headers(Status, Rest, []).

parse_headers(Status, Raw, Headers) ->
    case erlang:decode_packet(httph_bin, Raw, []) of
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            parse_headers(Status, Rest, [{header_name(Name), Value} | Headers]);
        {ok, http_eoh, Body} ->
            {Status, Headers, Body}
    end.

header_name(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name));
header_name(Name) when is_binary(Name) -> string:lowercase(Name).

free_port() ->
    {ok, Listen} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.
