%%%-------------------------------------------------------------------
%%% @author Juan Jose Comellas <juanjo@comellas.org>
%%% @copyright (C) 2011-2012 Juan Jose Comellas
%%% @doc MercadoLibre API module to handle paging through API results.
%%% @end
%%%
%%% This source file is subject to the New BSD License. You should have received
%%% a copy of the New BSD license with this software. If not, it can be
%%% retrieved from: http://www.opensource.org/licenses/bsd-license.php
%%%-------------------------------------------------------------------
-module(mlapi_async_pager).
-author('Juan Jose Comellas <juanjo@comellas.org>').

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/2, next/1, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("include/mlapi.hrl").

-define(SERVER, ?MODULE).
-define(DEFAULT_OFFSET, 0).
-define(DEFAULT_LIMIT, 50).

-type local_name()                              :: atom().
-type global_name()                             :: term().
-type server_name()                             :: local_name() | {local_name(), node()} | {global, global_name()}.
-type server_ref()                              :: server_name() | pid().

-type callback_fun()                            :: fun((mlapi_pager:position() | error, mlapi:ejson() | mlapi:error()) -> term()).
-type fetch_page_fun()                          :: fun((mlapi_offset(), mlapi_limit()) -> mlapi:ejson() | mlapi:error()).

-type arg()                                     :: {callback, callback_fun()} | {fetch_page, fetch_page_fun()} |
                                                   {offset, non_neg_integer()} | {limit, non_neg_integer()}.

-record(state, {
          paging_scheme                         :: mlapi_pager:paging_scheme(),
          initial_offset                        :: non_neg_integer(),
          offset                                :: non_neg_integer(),
          limit                                 :: non_neg_integer(),
          callback                              :: callback_fun(),
          fetch_page                            :: fetch_page_fun()
         }).


%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server.
-spec start_link([arg()]) -> {ok, pid()} | ignore | {error, Reason :: term()}.
start_link(Args) when is_list(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% @doc Starts the server with a registered name.
-spec start_link(server_name(), [arg()]) -> {ok, pid()} | ignore | {error, Reason :: term()}.
start_link(ServerName, Args) when is_list(Args) ->
    gen_server:start_link(ServerName, ?MODULE, Args, []).


%% @doc Retrieve the next page of results.
-spec next(server_ref()) -> ok.
next(ServerRef) ->
    gen_server:cast(ServerRef, next).


%% @doc Stop the pager process.
-spec stop(server_ref()) -> ok.
stop(ServerRef) ->
    gen_server:cast(ServerRef, stop).



%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec init([arg()]) -> {ok, #state{}, timeout()}.
init(Args) ->
    InitialOffset = proplists:get_value(offset, Args, ?DEFAULT_OFFSET),
    State = #state{
      paging_scheme = proplists:get_value(paging_scheme, Args),
      initial_offset = InitialOffset,
      offset = InitialOffset,
      %% FIXME the limit passed by the caller is the global limit (i.e. the total
      %%       number of documents to be retrieved from MLAPI), not the one to be
      %%       used for each individual request.
      limit = proplists:get_value(limit, Args, ?DEFAULT_LIMIT),
      callback = proplists:get_value(callback, Args),
      fetch_page = proplists:get_value(fetch_page, Args)
     },
    {ok, State, 0}.


%% @private
%% @doc Handle call messages.
-spec handle_call(Request :: term(), From :: term(), #state{}) -> {reply, {error, {badarg, Request :: term()}}, #state{}}.
handle_call(Request, _From, State) ->
    Reply = {error, {badarg, Request}},
    {reply, Reply, State}.


%% @private
%% @doc Handle cast messages.
-spec handle_cast(next | stop, #state{}) -> {stop, normal, #state{}} | {noreply, #state{}}.
handle_cast(next, State) ->
    io:format("Fetching page: offset=~w; limit=~w~n", [State#state.offset, State#state.limit]),
    case (State#state.fetch_page)(State#state.offset, State#state.limit) of
        {error, _Reason} = Error ->
            %% If the last request to the server returned an error, propagate the error
            %% to the owner and stop the current process.
            (State#state.callback)(error, Error),
            {stop, normal, State};
        Page ->
            case kvc:path(<<"paging">>, Page) of
                [] ->
                    %% If there is no 'paging' section in the returned JSON document
                    %% propagate an error to the caller and shutdown the process.
                    (State#state.callback)(error, {error, {paging_not_found, Page}}),
                    {stop, normal, State};
                Paging ->
                    Total = kvc:path(<<"total">>, Paging),
                    Offset = kvc:path(<<"offset">>, Paging),
                    Limit = kvc:path(<<"limit">>, Paging),
                    Position = mlapi_pager:page_position(State, Offset, Total, Limit),
                    %% io:format("Current paging node (~p): ~p~n", [Position, Paging]),
                    %% Return the result to the owner as soon as possible
                    (State#state.callback)(Position, Page),
                    if
                        Position =:= first orelse Position =:= middle ->
                            NextOffset = Offset + Limit,
                            {noreply, State#state{offset = NextOffset}};
                        true ->
                            %% We've either reached the last page or the paging information is invalid;
                            %% stop the process.
                            {stop, normal, State}
                    end
            end
    end;
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.


%% @private
%% @doc Handle all non call/cast messages.
-spec handle_info(timeout, #state{}) -> {noreply, #state{}}.
handle_info(timeout, State) ->
    handle_cast(next, State);
handle_info(_Info, State) ->
    {noreply, State}.


%% @private
%% @doc This function is called by a gen_server when it is about to
%%      terminate. It should be the opposite of Module:init/1 and do any
%%      necessary cleaning up. When it returns, the gen_server terminates
%%      with Reason. The return value is ignored.
-spec terminate(Reason :: term(), #state{}) -> ok.
terminate(_Reason, _State) ->
    ok.


%% @private
%% @doc Convert process state when code is changed.
-spec code_change(OldVsn :: term(), #state{}, Extra :: term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================
