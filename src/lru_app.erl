-module('lru_app').
-author('VSolenkov').

-behavior(application).

-export([
    start/2,
    stop/1,
    prep_stop/1
]).


start(_StartType,_StartArgs) ->
    lru_sup:start_link().

stop(_ETS_TABLES) ->
    ok.

prep_stop(ETS_TABLES) ->
    lru_utils:ets_reset(ETS_TABLES),
    ok.
