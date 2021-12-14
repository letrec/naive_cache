-module(naive_cache_SUITE).
-author("https://github.com/letrec").

-include_lib("stdlib/include/assert.hrl").

-compile(export_all).
-compile(nowarn_export_all).

start_stop_test() ->
    CacheRef = naive_cache:start(fun(X) -> X end),
    ok = naive_cache:stop(CacheRef).

get_test() ->
    CacheRef = naive_cache:start(fun(X) -> X end),
    ?assertEqual(42, naive_cache:get(CacheRef, 42)),
    ?assertEqual(42, naive_cache:get(CacheRef, 42)),
    ok = naive_cache:stop(CacheRef).

get_failed_test() ->
    CacheRef = naive_cache:start(fun(X) -> X / 0 end),
    ?assertEqual(badarith, naive_cache:get(CacheRef, 42)),
    ?assertEqual(badarith, naive_cache:get(CacheRef, 42)),
    ok = naive_cache:stop(CacheRef).