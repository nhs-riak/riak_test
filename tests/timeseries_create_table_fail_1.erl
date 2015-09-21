-module(timeseries_create_table_fail_1).

-behavior(riak_test).

-export([
	 confirm/0
	]).

-import(timeseries_util, [
			  get_ddl/1,
			  confirm_create/3
			  ]).

confirm() ->
    Cluster = single,
    DDL = get_ddl(shortkey_fail),
    Expected = {ok,"some error message, yeah?"},
    confirm_create(Cluster, DDL, Expected).