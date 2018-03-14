%%%-------------------------------------------------------------------
%%% @author Russell Brown <russell@wombat.me>
%% Copyright (c) 2018 Dataloch LTD.
%%% @doc

%%% Test originally for https://github.com/basho/riak_repl/issues/772
%%% but during writing uncovered an odd bug
%%% https://github.com/basho/riak_repl/issues/778.

%%% @end
%%% Created : 28 Feb 2018 by Russell Brown <russell@wombat.me>
%%%-------------------------------------------------------------------
-module(repl_aae_fail).

-behaviour(riak_test).
-export([confirm/0]).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

-define(WORKERS, 20).
-define(RING_SIZE, 8).

cluster_conf() ->
    [
     {riak_repl,
      [
       %% turn off fullsync
       {fullsync_strategy, aae},
       {fullsync_direct_limit, 1000},
       {fullsync_direct_percentage_limit, 10},
       {fullsync_on_connect, false},
       {fullsync_interval, disabled},
       {max_fssource_cluster, ?WORKERS},
       {max_fssource_node, ?WORKERS},
       {max_fssink_node, ?WORKERS},
       {rtq_max_bytes, 1048576}
      ]}
    ].

%% @doc riak_test entry point
confirm() ->
    %% Test two clusters of the current version
    SetupData = setup(),
    %% add intercept

    fullsync_test(SetupData),
    pass.

setup() ->
    %% NOTE: ring_size < workers
    rt:set_conf(all, [{"buckets.default.allow_mult", "false"}, {"ring_size", integer_to_list(?RING_SIZE)}]),

    {LeaderA, LeaderB, _, _} = ClusterNodes = make_clusters(),

    PBA = rt:pbc(LeaderA),
    PBB = rt:pbc(LeaderB),

    connect_clusters(LeaderA, LeaderB),
    {ClusterNodes, PBA, PBB}.

fullsync_test({ClusterNodes, PBA, PBB}) ->
    {LeaderA, LeaderB, ANodes, _BNodes} = ClusterNodes,
    %% Enable FS replication from cluster "A" to cluster "B"
    lager:info("Enabling fullsync between ~p and ~p", [LeaderA, LeaderB]),
    enable_fullsync(LeaderA, ANodes),

    Bucket = <<"fullsync-kicked">>,

    lager:info("doing puts on A, bucket:~p", [Bucket]),

    write_n(10, Bucket, PBA),

    {SyncTime1, _} = timer:tc(repl_util,
                              start_and_wait_until_fullsync_complete,
                              [LeaderA]),

    lager:info("Fullsync completed in ~p seconds", [SyncTime1/1000/1000]),

    NotFounds = read_verify_n(10, Bucket, PBB),

    ?assertEqual([], NotFounds).

%% @doc Turn on fullsync replication on the cluster lead by LeaderA.
%%      The clusters must already have been named and connected.
enable_fullsync(LeaderA, ANodes) ->
    repl_util:enable_fullsync(LeaderA, "B"),
    rt:wait_until_ring_converged(ANodes).

%% @doc Connect two clusters using a given name.
connect_cluster(Source, Port, Name) ->
    lager:info("Connecting ~p to ~p for cluster ~p.",
               [Source, Port, Name]),
    repl_util:connect_cluster(Source, "127.0.0.1", Port),
    ?assertEqual(ok, repl_util:wait_for_connection(Source, Name)).

%% @doc Connect two clusters for replication using their respective leader nodes.
connect_clusters(LeaderA, LeaderB) ->
    Port = repl_util:get_port(LeaderB),
    lager:info("connect cluster A:~p to B on port ~p", [LeaderA, Port]),
    repl_util:connect_cluster(LeaderA, "127.0.0.1", Port),
    ?assertEqual(ok, repl_util:wait_for_connection(LeaderA, "B")).

deploy_nodes(NumNodes) ->
    rt:deploy_nodes(NumNodes, cluster_conf(), [riak_kv, riak_repl]).

%% @doc Create two clusters of 1 node each and connect them for replication:
%%      Cluster "A" -> cluster "B"
make_clusters() ->
    NumNodes = rt_config:get(num_nodes, 2),
    ClusterASize = rt_config:get(cluster_a_size, 1),

    lager:info("Deploy ~p nodes", [NumNodes]),
    Nodes = deploy_nodes(NumNodes),
    {ANodes, BNodes} = lists:split(ClusterASize, Nodes),
    lager:info("ANodes: ~p", [ANodes]),
    lager:info("BNodes: ~p", [BNodes]),

    lager:info("Build cluster A"),
    repl_util:make_cluster(ANodes),

    lager:info("Build cluster B"),
    repl_util:make_cluster(BNodes),

    AFirst = hd(ANodes),
    BFirst = hd(BNodes),

    %% Name the clusters
    repl_util:name_cluster(AFirst, "A"),
    repl_util:name_cluster(BFirst, "B"),

    lager:info("Waiting for convergence."),
    rt:wait_until_ring_converged(ANodes),
    rt:wait_until_ring_converged(BNodes),

    lager:info("Waiting for transfers to complete."),
    rt:wait_until_transfers_complete(ANodes),
    rt:wait_until_transfers_complete(BNodes),

    %% get the leader for the first cluster
    lager:info("waiting for leader to converge on cluster A"),
    ?assertEqual(ok, repl_util:wait_until_leader_converge(ANodes)),

    %% get the leader for the second cluster
    lager:info("waiting for leader to converge on cluster B"),
    ?assertEqual(ok, repl_util:wait_until_leader_converge(BNodes)),

    ALeader = repl_util:get_leader(hd(ANodes)),
    BLeader = repl_util:get_leader(hd(BNodes)),

    lager:info("ALeader: ~p BLeader: ~p", [ALeader, BLeader]),
    {ALeader, BLeader, ANodes, BNodes}.

write_n(0, _B, _C) ->
    ok;
write_n(N, B, C) ->
    K = <<N:32/integer>>,
    O = riakc_obj:new(B, K, K),
    ok = riakc_pb_socket:put(C, O, [{pw, 3}]),
    write_n(N-1, B, C).

read_verify_n(N, B, C) ->
    read_verify_n(N, 3, B, C, []).

read_verify_n(0, _Retries, _B, _C, Acc) ->
    Acc;
read_verify_n(N, 0, B, C, Acc) ->
    read_verify_n(N-1, 3, B, C, [N | Acc]);
read_verify_n(N, Retries, B, C, Acc) ->
    K = <<N:32/integer>>,
    ReadResult =  riakc_pb_socket:get(C, B, K),
    case ReadResult of
        {ok, ReadObj} ->
            ?assertEqual(K, riakc_obj:get_value(ReadObj)),
            read_verify_n(N-1, 3, B, C, Acc);
        Err ->
            lager:info("Failed to read ~p with error ~p, retrying ~p more times",
                       [{B, K}, Err, Retries]),
            timer:sleep(100),
            read_verify_n(N, Retries-1, B, C, Acc)
    end.
