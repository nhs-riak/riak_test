%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc
%% This gen_server is reponsible for bootstrapping consensus ensembles
%% used by riak_kv to provide strong consistency. The server polls the
%% ring periodically and registers any missing ensembles with the
%% riak_ensemble_manager.

-module(riak_kv_ensembles).
-behaviour(gen_server).

%% API
-export([start_link/0]).

%% Support API
-export([ensembles/0,
         check_quorum/0,
         count_quorum/0,
         check_membership/0,
         check_membership2/0]).

%% Exported for debugging
-export([required_ensembles/1,
         required_members/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {last_ring_id :: term()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ensembles() ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    required_ensembles(Ring).

check_quorum() ->
    [riak_ensemble_manager:check_quorum(Ens, 2000) || Ens <- ensembles()].

count_quorum() ->
    [riak_ensemble_manager:count_quorum(Ens, 10000) || Ens <- ensembles()].

check_membership() ->
    {ok, Ring, CHBin} = riak_core_ring_manager:get_raw_ring_chashbin(),
    Ensembles = required_ensembles(Ring),
    [check_membership(Ensemble, CHBin) || Ensemble <- Ensembles].

check_membership2() ->
    {ok, Ring, CHBin} = riak_core_ring_manager:get_raw_ring_chashbin(),
    Ensembles = required_ensembles(Ring),
    [{Ens, check_membership(Ens, CHBin)} || Ens <- Ensembles].

check_membership(Ensemble, CHBin) ->
    Current = riak_ensemble_manager:get_members(Ensemble),
    Required = required_members(Ensemble, CHBin),
    lists:sort(Current) == lists:sort(Required).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    schedule_tick(),
    {ok, #state{last_ring_id = undefined}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    State2 = tick(State),
    schedule_tick(),
    {noreply, State2};

handle_info(reset_ring_id, State) ->
    State2 = State#state{last_ring_id=undefined},
    {noreply, State2};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

schedule_tick() ->
    erlang:send_after(10000, self(), tick).

reset_ring_id() ->
    self() ! reset_ring_id.

tick(State=#state{last_ring_id=LastID}) ->
    case riak_core_ring_manager:get_ring_id() of
        LastID ->
            State;
        RingID ->
            maybe_bootstrap_ensembles(),
            State#state{last_ring_id=RingID}
    end.

maybe_bootstrap_ensembles() ->
    case riak_ensemble_manager:enabled() of
        false ->
            ok;
        true ->
            {ok, Ring, CHBin} = riak_core_ring_manager:get_raw_ring_chashbin(),
            IsClaimant = (riak_core_ring:claimant(Ring) == node()),
            IsReady = riak_core_ring:ring_ready(Ring),
            case IsClaimant and IsReady of
                true ->
                    bootstrap_preflists(Ring, CHBin);
                false ->
                    ok
            end
    end.

bootstrap_preflists(Ring, CHBin) ->
    %% TODO: We have no notion of deleting ensembles. Nor do we check if
    %%       we should. Thus, ring resizing (shrinking) is broken.
    Required = required_ensembles(Ring),
    Ensembles = case riak_ensemble_manager:known_ensembles() of
                    {ok, KnownEns} ->
                        KnownEns;
                    _ ->
                        []
                end,
    Known = orddict:fetch_keys(Ensembles),
    Need = Required -- Known,
    L = [begin
             Peers = required_members(Ensemble, CHBin),
             riak_ensemble_manager:create_ensemble(Ensemble, undefined, Peers,
                                                   riak_kv_ensemble_backend, [])
         end || Ensemble <- Need],
    Failed = [Result || Result <- L,
                        Result =/= ok],
    (Failed =:= []) orelse reset_ring_id(),
    ok.

required_ensembles(Ring) ->
    AllN = riak_core_bucket:all_n(Ring),
    Owners = riak_core_ring:all_owners(Ring),
    [{kv, Idx, N} || {Idx, _} <- Owners,
                     N <- AllN].

required_members({kv, Idx, N}, CHBin) ->
    {PL, _} = chashbin:itr_pop(N, chashbin:exact_iterator(Idx, CHBin)),
    %% TODO: Make ensembles/peers use ensemble/peer as actual peer name so this is unneeded
    [{{kv, Idx, N, Idx2}, Node} || {Idx2, Node} <- PL].