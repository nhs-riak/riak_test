# Upgrade And Downgrade Tests For `riak_test`

## Introduction

This document outlines how to write upgrade and downgrade tests for `riak_kv` using the upgrade/downgrade framework.

## Purpose

The purpose of the framework is to separate out the mechanics of upgrading and downgrading clusters from the specifics of tests.

## Scope

Typically a particular test is associated with a particular upgrade path - eg from `Vsn n` to `Vsn n + 1`

## Note

This test framework is written as a `common test` that runs under `riak_test`.

## Overview

The ladder defined here takes a cluster from all the nodes being in the old-original state, up via mixed clusters of old and new machines to the full cluster in the upgraded state, and back down to the orginal cluster.

Tests are run against all scenarios:
* new feature against a new version node in a mixed cluster
* new feature against an old version node in a mixed cluster
* etc, etc

Typically an upgrade introduces new features and the upgrade/downgrade framework therefore provides two testing streams:
* a regression stream - which checks that features that worked in the old version continue to work in the new one
* a new feature stream - which checks that the capabilities in `riak_core` are correctly specified and that the new feature becomes available when the cluster is operational on the upgrade route - with appropriate error messages in the mixed state, as well as the correct error messages and behaviour on the downgrade route

There are a number of potential glitches that might need to be handled in an upgrade/downgrade:
* client changes - some features need a new client to use
* config changes - some features need to be enabled to work in the new version by specific keys in the config which need to not exist in the old version, or to have values changed back
* the capabilities in `riak_core` take time to settle down and this non-deterministic behaviour needs to be handled in a deterministic way by waiting for them to settle down

The framework offers options for all these things. Some of these can be quite complex - like using Erlang slave nodes to run old version clients in the downgrade phase.

## Basic Structure Of Tests

The data structures used in the framework are defined in the file `tests/kv_updown_util.hrl`

These data structures are `#scenario{}` and `#failure_report{}`

**TODO**: Currently the data structures are all based on TS concepts like `create table`, `insert data` and `select` - these are wrapped up in a `#test_set{}` record - this all needs to be ripped out and replaced.

The actual runner that is used is in the `.part` file `tests/kv_updowngrade_test.part` which is included in hour test.

This provides the skeleton code your test requires. Your test includes this `.part` file and provides three functions which it requires:
* `make_initial_config/1`
* `make_scenario_invariants/1`
* `make_scenarios/0`

Both of the arity-1 functions take a single parameter which is an Erlang `common_test` config data structure as defined here:
http://erlang.org/doc/apps/common_test/config_file_chapter.html

Essentially you define test specific initial configuration in `make_initial_config/1` - saying things like *does this test need to revert to the old client on downgrade* and other limited options.

The function `make_scenario_invariants` appends a tuple to the `config` of the form `{default_tests, TestSets}` where the `TestSets` are of the type `#test_set{}` defined in `kv_updown_util.hrl`. These test sets will be run in all scenarios.

The actual tests themsleves are returned by the function `make_scenarios` - this has the return type of `[#scenarios{}]`


## How To Write An Upgrade/Downgrade Test

Read one of the existing ones - and copy it replacing its tests and invariants with yours.

If that doens't work - checkout the branch `riak_ts-develop` and inspect the varous `tests/*updown*` tests in there - with the relevant `.part` and `*updown_util.*` files which this code is based on.

## How To Run An Upgrade/Downgrade Test

**TODO**: fucked if I can remember
