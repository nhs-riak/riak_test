%% -------------------------------------------------------------------
%%% @copyright (C) 2018, NHS Digital
%%% @doc
%%% riak_test for soft-limit vnode polling and put fsm routing
%%% see riak/1661 for details.
%%% @end

-module(verify_vnode_polling).
-behavior(riak_test).
-compile([export_all]).
-export([confirm/0]).

-include_lib("eunit/include/eunit.hrl").

-define(BUCKET, <<"bucket">>).
-define(KEY, <<"key">>).
-define(VALUE, <<"value">>).

-define(RING_SIZE, 8).

confirm() ->
    Conf = [
            {riak_kv, [{anti_entropy, {off, []}}]},
            {riak_core, [{default_bucket_props, [{allow_mult, true},
                                                 {dvv_enabled, true},
                                                 {ring_creation_size, ?RING_SIZE},
                                                 {vnode_management_timer, 1000},
                                                 {handoff_concurrency, 100},
                                                 {vnode_inactivity_timeout, 1000}]}]}],

    [Node1|_]=Nodes = rt:build_cluster(5, Conf),

    lager:info("starting tracing"),

    rt_redbug:trace(Nodes, ["riak_core_vnode_proxy:soft_load_mailbox_check/2->return"]),

    Preflist = rt:get_preflist(Node1, ?BUCKET, ?KEY),

    lager:info("Got preflist"),
    lager:info("Preflist ~p~n", [Preflist]),

    %% get the head of the preflist and a client for it
    [{{_Idx, Node}, _Type} | _Rest] = Preflist,

    PBClient = rt:pbc(Node),

    lager:info("Attempting to write key"),

    %% Write key, all well
    rt:pbc_write(PBClient, ?BUCKET, ?KEY, ?VALUE),

    %% intercept the local/head proxy to return a soft-loaded proxy,
    %% check for a forward
    lager:info("adding intercept to ~p", [Nodes]),

    ok = rt_intercept:add(Node, {riak_core_vnode_proxy,
     				 [
     				  {{soft_load_mailbox_check, 2}, soft_load_mbox}
     				 ]}),

    %% Expect it to be forwarded for coordination
    rt:pbc_write(PBClient, ?BUCKET, ?KEY, ?VALUE),

    pass.
