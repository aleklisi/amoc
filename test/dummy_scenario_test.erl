-module(dummy_scenario_test).

-behaviour(amoc_scenario).

-export([start/1]).
-export([init/0]).

-spec init() -> ok.
init() ->
    ok.

start(Id) when Id == 2 ->
    1 = 2;
start(Id) when Id == 3 ->
    exit(test_crush_reason);
start(Id) when Id == 5; Id == 6 ->
    amoc_user:stop();
start(_Id) ->
    timer:sleep(timer:minutes(1)),
    amoc_user:stop().
