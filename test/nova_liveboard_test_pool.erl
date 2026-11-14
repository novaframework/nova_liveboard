-module(nova_liveboard_test_pool).
-moduledoc "A registered process whose state is whatever a test gives it.".
-behaviour(gen_server).

-export([start/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-spec start(atom(), term()) -> gen_server:start_ret().
start(Name, State) ->
    gen_server:start({local, Name}, ?MODULE, State, []).

-spec init(term()) -> {ok, term()}.
init(State) ->
    {ok, State}.

-spec handle_call(term(), gen_server:from(), term()) -> {reply, ok, term()}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), term()) -> {noreply, term()}.
handle_cast(_Message, State) ->
    {noreply, State}.
