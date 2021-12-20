-module(naive_cache_SUITE).

-include_lib("stdlib/include/assert.hrl").

-compile(export_all).
-compile(nowarn_export_all).

id(X) ->
    X.

div_by_zero(X) ->
    X / 0.

start_stop_test() ->
    {Pid, _Tid} = naive_cache:start(),
    ok = naive_cache:stop(Pid).

get_test() ->
    {Pid, Tid} = naive_cache:start(),
    naive_cache:get(Tid, fun(X) -> X end, 42),
    ?assertEqual(42, naive_cache:get(Tid, fun id/1, 42)),
    ?assertEqual(42, naive_cache:get(Tid, fun id/1, 42)),
    ok = naive_cache:stop(Pid).

get_failed_test() ->
    {Pid, Tid} = naive_cache:start(),
    ?assertThrow(badarith, naive_cache:get(Tid, fun div_by_zero/1, 42)),
    ?assertThrow(badarith, naive_cache:get(Tid, fun div_by_zero/1, 42)),
    ok = naive_cache:stop(Pid).