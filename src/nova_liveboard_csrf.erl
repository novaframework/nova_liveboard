-module(nova_liveboard_csrf).
-moduledoc """
Cross-site request forgery protection for the liveboard's POST actions.

The liveboard has no session of its own (authentication belongs to the host),
so it uses a double-submit token it issues itself. A request is accepted only
when both checks pass:

1. **Same origin.** If the browser sent `Sec-Fetch-Site`, it must be
   `same-origin`. Otherwise the `Origin` header must be present and either
   name the host and port the request was sent to or be listed in the
   `trusted_origins` application env. A request with neither header is
   refused.
2. **Token.** The `x-csrf-token` request header must equal the
   `nova_liveboard_csrf` cookie, compared in constant time. The cookie is
   `HttpOnly`, `SameSite=Strict` and scoped to the liveboard's prefix; the
   page carries the same value in `data-liveboard-csrf` on `<body>`, which the
   Datastar post expression sends back as the header.

`trusted_origins` is only needed when the liveboard is served over plain HTTP
behind a proxy that rewrites the `Host` header, so that the origin the browser
sees differs from the host Nova sees. Browsers send `Sec-Fetch-Site` on HTTPS
and on localhost, where no configuration is needed.
""".

-export([token/1, verify/1]).

-define(COOKIE, ~"nova_liveboard_csrf").
-define(HEADER, ~"x-csrf-token").
-define(TOKEN_BYTES, 32).
-define(TOKEN_CHARS, 43).

-type rejection() :: cross_site | origin_mismatch | origin_missing | token_missing | token_mismatch.
-export_type([rejection/0]).

-doc """
The token to render into a page. Reuses the request's cookie when it has a
well-formed one; otherwise issues a new token and sets the cookie on the
returned request, which the controller must hand back to Nova.
""".
-spec token(cowboy_req:req()) -> {binary(), cowboy_req:req()}.
token(Req) ->
    case cookie(Req) of
        {ok, Token} ->
            {Token, Req};
        error ->
            Token = base64:encode(crypto:strong_rand_bytes(?TOKEN_BYTES), #{
                mode => urlsafe, padding => false
            }),
            Opts = #{
                path => cookie_path(),
                http_only => true,
                same_site => strict,
                secure => secure(Req)
            },
            {Token, cowboy_req:set_resp_cookie(?COOKIE, Token, Req, Opts)}
    end.

-doc "Check a state-changing request. See the moduledoc for the rules.".
-spec verify(cowboy_req:req()) -> ok | {error, rejection()}.
verify(Req) ->
    case same_origin(Req) of
        ok -> token_matches(Req);
        {error, _} = Error -> Error
    end.

same_origin(Req) ->
    case header(~"sec-fetch-site", Req) of
        ~"same-origin" -> ok;
        undefined -> known_origin(header(~"origin", Req), Req);
        _ -> {error, cross_site}
    end.

known_origin(undefined, _Req) ->
    {error, origin_missing};
known_origin(Origin, Req) ->
    case
        lists:member(Origin, nova_liveboard:trusted_origins()) orelse
            targets_this_host(authority(Origin), Req)
    of
        true -> ok;
        false -> {error, origin_mismatch}
    end.

targets_this_host({ok, Authority}, Req) ->
    lists:member(ascii_lowercase(Authority), request_authorities(Req));
targets_this_host(error, _Req) ->
    false.

-spec authority(binary()) -> {ok, binary()} | error.
authority(<<"http://", Authority/binary>>) when Authority =/= ~"" -> {ok, Authority};
authority(<<"https://", Authority/binary>>) when Authority =/= ~"" -> {ok, Authority};
authority(_) -> error.

%% HTTP/2 requests carry no Host header, only the parsed host and port.
-spec request_authorities(cowboy_req:req()) -> [binary()].
request_authorities(Req) ->
    case header(~"host", Req) of
        undefined ->
            parsed_authorities(maps:get(host, Req, undefined), maps:get(port, Req, undefined));
        Host ->
            [ascii_lowercase(Host)]
    end.

parsed_authorities(Host, Port) when is_binary(Host), is_integer(Port) ->
    WithPort = <<(ascii_lowercase(Host))/binary, ":", (integer_to_binary(Port))/binary>>,
    case Port =:= 80 orelse Port =:= 443 of
        true -> [WithPort, ascii_lowercase(Host)];
        false -> [WithPort]
    end;
parsed_authorities(_Host, _Port) ->
    [].

-spec ascii_lowercase(binary()) -> binary().
ascii_lowercase(Bin) ->
    <<<<(ascii_lowercase_byte(Byte))>> || <<Byte>> <= Bin>>.

ascii_lowercase_byte(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
ascii_lowercase_byte(Byte) -> Byte.

token_matches(Req) ->
    case {cookie(Req), header(?HEADER, Req)} of
        {{ok, Cookie}, Sent} when is_binary(Sent), byte_size(Sent) =:= ?TOKEN_CHARS ->
            case crypto:hash_equals(Cookie, Sent) of
                true -> ok;
                false -> {error, token_mismatch}
            end;
        {{ok, _Cookie}, undefined} ->
            {error, token_missing};
        {error, _Sent} ->
            {error, token_missing};
        _ ->
            {error, token_mismatch}
    end.

-spec cookie(cowboy_req:req()) -> {ok, binary()} | error.
cookie(Req) ->
    try cowboy_req:parse_cookies(Req) of
        Cookies ->
            case lists:keyfind(?COOKIE, 1, Cookies) of
                {_, Token} when is_binary(Token), byte_size(Token) =:= ?TOKEN_CHARS ->
                    case well_formed(Token) of
                        true -> {ok, Token};
                        false -> error
                    end;
                _ ->
                    error
            end
    catch
        _:_ -> error
    end.

cookie_path() ->
    case nova_liveboard:prefix() of
        ~"" -> ~"/";
        Prefix -> Prefix
    end.

well_formed(Token) ->
    <<<<C>> || <<C>> <= Token, token_char(C)>> =:= Token.

token_char(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_.

secure(Req) ->
    maps:get(scheme, Req, ~"http") =:= ~"https" orelse
        header(~"x-forwarded-proto", Req) =:= ~"https".

-spec header(binary(), cowboy_req:req()) -> binary() | undefined.
header(Name, Req) ->
    case maps:get(Name, maps:get(headers, Req, #{}), undefined) of
        Value when is_binary(Value) -> Value;
        _ -> undefined
    end.
