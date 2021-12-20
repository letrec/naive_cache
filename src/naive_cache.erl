-module(naive_cache).

-include_lib("stdlib/include/ms_transform.hrl").

-import(lists, [
    foreach/2,
    reverse/1
]).

-export([
    start/0,
    stop/1,
    init/1,
    get/3
]).

start() ->
    Pid = spawn(?MODULE, init, [self()]),
    receive
        {Pid, {?MODULE, Table}} -> {Pid, Table}
    end.

stop(Pid) ->
    Pid ! stop,
    ok.

init(From) ->
    Cached = ets:new(cached, [set, public, {read_concurrency, true}, {write_concurrency, true}]),
    From ! {self(), {?MODULE, Cached}},
    loop().

% key states: not present, being fetched, present

eval_key(Tid, Fun, Key, Pid) ->
    Eval = fun() ->
        try Fun(Key) of
            Val -> eval_succeeded(Tid, Fun, Key, Val, Pid)
        catch
            _:Reason -> eval_failed(Tid, Fun, Key, Reason, Pid)
        end
    end,
    spawn(Eval).

register_first_waiter(Tid, Fun, Key, Pid) ->
    case ets:insert_new(Tid, {Key, wait, [Pid]}) of
        true  -> eval_key(Tid, Fun, Key, Pid);
        false -> register_additional_waiter(Tid, Fun, Key, Pid)
    end.

register_additional_waiter(Tid, Fun, Key, Pid) ->
    case ets:lookup(Tid, Key) of
        % the value is here and there's no need to wait anymore
        [{_key, value, Val}] -> Pid ! {ok, Val};
        % previous attempt failed, failures are not cached, so we need to try again
        [] -> register_first_waiter(Tid, Fun, Key, Pid);
        [{_key, wait, Pids}] ->
            MS = ets:fun2ms(fun({K, wait, Ps}) when K =:= Key, Ps =:= Pids -> {K, wait, [Pid | Ps]} end),
            case ets:select_replace(Tid, MS) of
                1 -> ok;
                0 -> register_additional_waiter(Tid, Fun, Key, Pid)
            end
    end.

eval_succeeded(Tid, Fun, Key, Val, Pid) ->
    case ets:lookup(Tid, Key) of
        [{_key, wait, Pids}] ->
            MS = ets:fun2ms(fun({K, wait, Ps}) when K =:= Key, Ps =:= Pids -> {K, value, Val} end),
            case ets:select_replace(Tid, MS) of
                1 -> foreach(fun(P) -> P ! {ok, Val} end, reverse(Pids));
                0 -> eval_succeeded(Tid, Fun, Key, Val, Pid)
            end
    end.

eval_failed(Tid, Fun, Key, Reason, Pid) ->
    case ets:lookup(Tid, Key) of
        [{_key, wait, Pids}] ->
            MS = ets:fun2ms(fun({K, wait, Ps}) -> K =:= Key andalso Ps =:= Pids end),
            case ets:select_delete(Tid, MS) of
                1 -> foreach(fun(P) -> P ! {error, Reason} end, reverse(Pids));
                0 -> eval_failed(Tid, Fun, Key, Reason, Pid)
            end
    end.

get(Tid, Fun, Key) ->
    case ets:lookup(Tid, Key) of
        [{_key, value, Value}] ->
            Value;
        [] ->
            register_first_waiter(Tid, Fun, Key, self()),
            receive
                {ok, Value}     -> Value;
                {error, Reason} -> throw(Reason)
            end;
        [{_key, wait, _pids}] ->
            register_additional_waiter(Tid, Fun, Key, self()),
            receive
                {ok, Value}     -> Value;
                {error, Reason} -> throw(Reason)
            end
    end.

loop() ->
    receive
        stop -> ok
    end.
