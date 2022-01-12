-module(naive_cache).

-include_lib("stdlib/include/ms_transform.hrl").

-import(erlang, [
    monotonic_time/0
]).

-import(lists, [
    foreach/2,
    reverse/1
]).

-export([
    start/0,
    stop/1,
    init/1,
    get_async/3,
    get/3
]).

-record(pending, {key, pids, counters}).
-record(done, {key, value, time, counters}).

-define(counters_size, 2).
-define(hit_ix, 1).
-define(miss_ix, 2).
% -define(eval_time_ix, 3).

start() ->
    Pid = spawn(?MODULE, init, [self()]),
    receive
        {Pid, {?MODULE, Table}} -> {Pid, Table}
    end.

stop(Pid) ->
    Pid ! stop,
    ok.

init(From) ->
    Cache = ets:new(cache, [set, public, {read_concurrency, true}, {write_concurrency, true}]),
    From ! {self(), {?MODULE, Cache}},
    loop().

% key states: not present, being fetched, present

eval_key(Tid, Fun, Key, Pid) ->
    Eval = fun() ->
        Start = monotonic_time(),
        try Fun(Key) of
            Val -> eval_succeeded(Tid, Fun, Key, Val, monotonic_time() - Start, Pid)
        catch
            _:Reason -> eval_failed(Tid, Fun, Key, Reason, Pid)
        end
    end,
    spawn(Eval).

register_first_waiter(Tid, Fun, Key, Pid) ->
    Counters = counters:new(?counters_size, [write_concurrency]),
    counters:add(Counters, ?miss_ix, 1),
    case ets:insert_new(Tid, {Key, wait, [Pid], Counters}) of
        true  -> eval_key(Tid, Fun, Key, Pid);
        false -> register_additional_waiter(Tid, Fun, Key, Pid)
    end.

register_additional_waiter(Tid, Fun, Key, Pid) ->
    case ets:lookup(Tid, Key) of
        % the value is here and there's no need to wait anymore
        [{_key, value, Val, _Time, Counters}] ->
            counters:add(Counters, ?hit_ix, 1),
            Pid ! {ok, Val};
        % previous attempt failed, failures are not cached, so we need to try again
        [] -> register_first_waiter(Tid, Fun, Key, Pid);
        [{_key, wait, Pids, Counters}] ->
            MS = ets:fun2ms(fun({K, wait, Ps, Cs}) when K =:= Key, Ps =:= Pids -> {K, wait, [Pid | Ps], Cs} end),
            case ets:select_replace(Tid, MS) of
                1 -> counters:add(Counters, ?miss_ix, 1);
                0 -> register_additional_waiter(Tid, Fun, Key, Pid)
            end
    end.

eval_succeeded(Tid, Fun, Key, Val, Time, Pid) ->
    [{_key, wait, Pids, _Counters}] = ets:lookup(Tid, Key),
    MS = ets:fun2ms(fun({K, wait, Ps, Cs}) when K =:= Key, Ps =:= Pids -> {K, value, Val, Time, Cs} end),
    case ets:select_replace(Tid, MS) of
        1 -> foreach(fun(P) -> P ! {ok, Val} end, reverse(Pids));
        0 -> eval_succeeded(Tid, Fun, Key, Val, Time, Pid)
    end.

eval_failed(Tid, Fun, Key, Reason, Pid) ->
    [{_key, wait, Pids, _Counters}] = ets:lookup(Tid, Key),
    MS = ets:fun2ms(fun({K, wait, Ps, _Cs}) -> K =:= Key andalso Ps =:= Pids end),
    case ets:select_delete(Tid, MS) of
        1 -> foreach(fun(P) -> P ! {error, Reason} end, reverse(Pids));
        0 -> eval_failed(Tid, Fun, Key, Reason, Pid)
    end.

-spec get_async(ets:tid(), fun((any()) -> any()), any()) -> {ok, any()} | pending.
get_async(Tid, Fun, Key) ->
    case ets:lookup(Tid, Key) of
        [{_key, value, Value, _Time, Counters}] ->
            counters:add(Counters, ?hit_ix, 1),
            {ok, Value};
        [] ->
            register_first_waiter(Tid, Fun, Key, self()),
            pending;
        [{_key, wait, _pids}] ->
            register_additional_waiter(Tid, Fun, Key, self()),
            pending
    end.

get(Tid, Fun, Key) ->
    case get_async(Tid, Fun, Key) of
        {ok, Value} ->
            Value;
        pending ->
            receive
                {ok, Value}     -> Value;
                {error, Reason} -> throw(Reason)
            end
    end.

loop() ->
    receive
        stop -> ok
    end.
