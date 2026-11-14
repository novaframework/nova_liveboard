-module(nova_liveboard_test_auth).
-moduledoc "The HTTP basic auth callback from the README, used as the test fixture.".

-export([operators_only/1, identified/1, not_a_callback/0]).

operators_only(Req) ->
    case
        {application:get_env(nova_liveboard, test_login), cowboy_req:header(~"authorization", Req)}
    of
        {{ok, {User, Password}}, <<"Basic ", Given/binary>>} when
            is_binary(User), is_binary(Password)
        ->
            Expected = base64:encode(<<User/binary, ":", Password/binary>>),
            same(Given, Expected) orelse challenge();
        _ ->
            challenge()
    end.

%% Lets everyone in and names those who say who they are.
identified(Req) ->
    case cowboy_req:header(~"x-test-user", Req) of
        undefined -> true;
        User -> {true, #{user => User}}
    end.

not_a_callback() ->
    ok.

challenge() ->
    {false, 401, #{~"www-authenticate" => ~"Basic realm=\"liveboard\""}}.

same(A, B) ->
    crypto:hash_equals(crypto:hash(sha256, A), crypto:hash(sha256, B)).
