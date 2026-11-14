-module(nova_liveboard_redact).
-moduledoc """
Decides how much of five values the liveboard shows.

Most of what the liveboard renders is structure: names, pids, counts and
sizes. Five values can carry a secret, and everyone who can open the
liveboard would see it:

- the **path** of a traced request, which can hold a reset token, an API key
  or a signed link;
- the **name** of a port, which for a spawned program is its whole command
  line, arguments included;
- a supervisor **child id** that is not an atom, which is printed as a term
  and is often built from a connection or pool configuration;
- the **database name** and the **host** of a Kura repo, which come from its
  connection configuration and can be written as a URL with a user and a
  password in it. No other setting of that configuration is read for display,
  the password least of all.

What happens to them follows the `redact` application env:

- `standard` (the default): in a path, every segment of 20 or more bytes that
  contains a digit becomes `[redacted]`; a port name is cut after the program;
  a child id is printed, capped at 200 characters; in a database name or
  host, what stands before an `@` and what follows a `?` becomes `[redacted]`.
- `none`: the five values are shown as they are, capped in length.
- `all`: each of the five is shown as `[redacted]`.
- `{Module, Function}`: `Module:Function(Kind, Value)` is called with
  `request_path`, `port_name`, `child_id`, `database` or `database_host` and
  the value as a binary, and returns the binary to show. If it returns
  anything else or fails, the value is shown as `[redacted]`.

Anything else is treated as `all`.

A request path is redacted when the request is captured, so the tracer never
holds the original. The query string of a request is never captured at all.

The `standard` rule is a guess at what a token looks like, so it is a safety
net, not a guarantee: a short secret in a path is shown. Use `all` or a
callback when that matters.
""".

-export([request_path/1, port_name/1, child_id/1, database/1, database_host/1]).

-define(REDACTED, ~"[redacted]").
-define(TOKEN_BYTES, 20).
-define(MAX_BYTES, 512).
-define(MAX_PRINTED, 200).

-type kind() :: request_path | port_name | child_id | database | database_host.
-export_type([kind/0]).

-doc "The path of a traced request as the liveboard may keep and show it.".
-spec request_path(binary()) -> binary().
request_path(Path) ->
    case nova_liveboard:redact() of
        standard -> capped(without_tokens(Path));
        none -> capped(Path);
        all -> ?REDACTED;
        {callback, Callback} -> asked(Callback, request_path, Path)
    end.

-doc "The name of a port as the liveboard may show it.".
-spec port_name(binary()) -> binary().
port_name(Name) ->
    case nova_liveboard:redact() of
        standard -> capped(program(Name));
        none -> capped(Name);
        all -> ?REDACTED;
        {callback, Callback} -> asked(Callback, port_name, Name)
    end.

-doc "A supervisor child id that is not an atom, as the liveboard may show it.".
-spec child_id(term()) -> binary().
child_id(Id) ->
    case nova_liveboard:redact() of
        all -> ?REDACTED;
        {callback, Callback} -> asked(Callback, child_id, printed(Id));
        _ -> printed(Id)
    end.

-doc "The database name of a Kura repo as the liveboard may show it.".
-spec database(binary()) -> binary().
database(Name) ->
    connection_setting(database, Name).

-doc "The host of a Kura repo's database as the liveboard may show it.".
-spec database_host(binary()) -> binary().
database_host(Host) ->
    connection_setting(database_host, Host).

-spec connection_setting(database | database_host, binary()) -> binary().
connection_setting(Kind, Value) ->
    case nova_liveboard:redact() of
        standard -> capped(without_credentials(Value));
        none -> capped(Value);
        all -> ?REDACTED;
        {callback, Callback} -> asked(Callback, Kind, Value)
    end.

-spec asked({module(), atom()}, kind(), binary()) -> binary().
asked({Module, Function}, Kind, Value) ->
    try Module:Function(Kind, Value) of
        Shown when is_binary(Shown) -> capped(Shown);
        _ -> ?REDACTED
    catch
        _:_ -> ?REDACTED
    end.

-spec without_tokens(binary()) -> binary().
without_tokens(Path) ->
    Segments = [
        case token_like(Segment) of
            true -> ?REDACTED;
            false -> Segment
        end
     || Segment <- binary:split(Path, ~"/", [global])
    ],
    iolist_to_binary(lists:join(~"/", Segments)).

-spec token_like(binary()) -> boolean().
token_like(Segment) ->
    byte_size(Segment) >= ?TOKEN_BYTES andalso
        <<<<Byte>> || <<Byte>> <= Segment, Byte >= $0, Byte =< $9>> =/= ~"".

-spec program(binary()) -> binary().
program(Name) ->
    case binary:split(Name, [~" ", ~"\t"]) of
        [Program, _Arguments] -> <<Program/binary, " ", ?REDACTED/binary>>;
        [Program] -> Program
    end.

%% The query goes first: an `@` in it would otherwise pass for the end of the
%% user and password.
-spec without_credentials(binary()) -> binary().
without_credentials(Value) ->
    without_userinfo(without_query(Value)).

-spec without_query(binary()) -> binary().
without_query(Value) ->
    case binary:split(Value, ~"?") of
        [Before, _Query] -> iolist_to_binary([Before, ~"?", ?REDACTED]);
        [_] -> Value
    end.

-spec without_userinfo(binary()) -> binary().
without_userinfo(Value) ->
    case binary:matches(Value, ~"@") of
        [] ->
            Value;
        Matches ->
            {At, _Length} = lists:last(Matches),
            Scheme =
                case binary:match(Value, ~"://") of
                    {Start, Length} when Start < At -> binary:part(Value, 0, Start + Length);
                    _ -> ~""
                end,
            iolist_to_binary([Scheme, ?REDACTED, binary:part(Value, At, byte_size(Value) - At)])
    end.

-spec capped(binary()) -> binary().
capped(<<Head:?MAX_BYTES/binary, _, _/binary>>) -> <<Head/binary, "...">>;
capped(Value) -> Value.

-spec printed(term()) -> binary().
printed(Term) ->
    case
        unicode:characters_to_binary(io_lib:format("~0tp", [Term], [{chars_limit, ?MAX_PRINTED}]))
    of
        Printed when is_binary(Printed) -> Printed;
        {_, Readable, _Rest} -> Readable
    end.
