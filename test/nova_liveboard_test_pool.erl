-module(nova_liveboard_test_pool).
-moduledoc """
A registered process that answers `stats` with the state a test gives it, as a
minato pool answers that call with its figures (minato v1.1.6
src/minato_pool.erl lines 673-676). With the state `blocked` it never
answers.
""".
-behaviour(gen_server).

-export([start/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-spec start(atom(), term()) -> gen_server:start_ret().
start(Name, State) ->
    gen_server:start({local, Name}, ?MODULE, State, []).

-spec init(term()) -> {ok, term()}.
init(State) ->
    {ok, State}.

-spec handle_call(term(), gen_server:from(), term()) ->
    {reply, term(), term()} | {noreply, term()}.
handle_call(stats, _From, blocked) ->
    {noreply, blocked};
handle_call(stats, _From, State) ->
    {reply, State, State};
handle_call(Message, _From, State) ->
    {reply, {error, {unknown_call, Message}}, State}.

-spec handle_cast(term(), term()) -> {noreply, term()}.
handle_cast(_Message, State) ->
    {noreply, State}.
