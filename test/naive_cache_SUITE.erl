-module(naive_cache_SUITE).

-include_lib("stdlib/include/assert.hrl").

-compile(export_all).
-compile(nowarn_export_all).

start_stop_test() ->
    {Pid, _Table} = naive_cache:start(fun(X) -> X end),
    ok = naive_cache:stop(Pid).

get_test() ->
    {Pid, Table} = naive_cache:start(fun(X) -> X end),
    ?assertEqual(42, naive_cache:get({Pid, Table}, 42)),
    ?assertEqual(42, naive_cache:get({Pid, Table}, 42)),
    ok = naive_cache:stop(Pid).

get_failed_test() ->
    {Pid, Table} = naive_cache:start(fun(X) -> X / 0 end),
    ?assertEqual(badarith, naive_cache:get({Pid, Table}, 42)),
    ?assertEqual(badarith, naive_cache:get({Pid, Table}, 42)),
    ok = naive_cache:stop(Pid).