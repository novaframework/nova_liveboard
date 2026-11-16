-module(nova_liveboard_optional_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, nova_liveboard_optional).

call_test_() ->
    [
        ?_assertEqual({ok, [2, 1]}, ?M:call(lists, reverse, [[1, 2]])),
        ?_assertEqual(absent, ?M:call(nova_liveboard_no_such_library, stats, [main])),
        ?_assertEqual(missing, ?M:call(lists, reverse, [[1], [2], [3]])),
        ?_assertEqual({raised, error, boom}, ?M:call(erlang, error, [boom])),
        ?_assertEqual({raised, exit, gone}, ?M:call(erlang, exit, [gone])),
        ?_assertEqual({raised, throw, ball}, ?M:call(erlang, throw, [ball]))
    ].

answer_test_() ->
    [
        ?_assertEqual({ok, [2, 1]}, answer(lists, reverse, [[1, 2]], 1000)),
        ?_assertEqual(absent, answer(nova_liveboard_no_such_library, stats, [main], 1000)),
        ?_assertEqual(missing, answer(lists, reverse, [[1], [2], [3]], 1000)),
        ?_assertEqual({raised, error, boom}, answer(erlang, error, [boom], 1000)),
        ?_assertEqual({raised, exit, gone}, answer(erlang, exit, [gone], 1000))
    ].

a_call_that_does_not_answer_is_given_up_and_killed_test() ->
    Started = erlang:monotonic_time(millisecond),
    Before = erlang:processes(),
    Request = ?M:start(timer, sleep, [infinity]),
    ?assertEqual(timeout, ?M:answer(Request, ?M:deadline(50))),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
    ?assertEqual([], [Pid || Pid <- erlang:processes() -- Before, working(Pid)]),
    ?assertEqual([], messages()).

an_answer_that_is_already_there_is_taken_after_the_deadline_test() ->
    Request = ?M:start(lists, reverse, [[1, 2]]),
    timer:sleep(50),
    ?assertEqual({ok, [2, 1]}, ?M:answer(Request, ?M:deadline(0))),
    ?assertEqual([], messages()).

a_call_that_fails_logs_nothing_test() ->
    ?assertEqual(
        ~"[]",
        nova_liveboard_test_log:logged(fun() ->
            {raised, error, {secret, ~"hunter2"}} =
                answer(erlang, error, [{secret, ~"hunter2"}], 1000)
        end)
    ).

answer(Module, Function, Arguments, Milliseconds) ->
    ?M:answer(?M:start(Module, Function, Arguments), ?M:deadline(Milliseconds)).

working(Pid) ->
    erlang:process_info(Pid, current_function) =:= {current_function, {timer, sleep, 1}}.

messages() ->
    receive
        Message -> [Message | messages()]
    after 0 -> []
    end.
