-module(naive_cache).

-import(lists, [
    foreach/2,
    reverse/1
]).

-export([
    start/1,
    stop/1,
    init/2,
    get/2
]).

start(F) ->
    Pid = spawn(?MODULE, init, [self(), F]),
    receive
        {Pid, {?MODULE, Table}} -> {Pid, Table}
    end.

stop(Pid) ->
    Pid ! stop,
    ok.

init(From, F) ->
    Cached = ets:new(cached, [set, protected, {read_concurrency, true}]),
    Pending = ets:new(pending, [set, private]),

    From ! {self(), {?MODULE, Cached}},

    loop({F, Cached, Pending}).

get({Server, Table}, Key) ->
    case ets:lookup(Table, Key) of
        [] ->
            io:format("Value for ~w is not in the cache~n", [Key]),
            Server ! {self(), {eval_key, Key}},
            receive
                {Server, Value} -> Value
            end;
        [{Key, Value}] ->
            io:format("Value for ~w is in the cache~n", [Key]),
            Value
    end.

loop({F, Cached, Pending} = S) ->
    receive
        stop ->
            ok;
        {From, {eval_key, Key}} ->
            case ets:lookup(Cached, Key) of
                [] ->
                    % TODO: consider using `ets:select_replace` instead of `ets:lookup`
                    case ets:lookup(Pending, Key) of
                        [] ->
                            true = ets:insert_new(Pending, {Key, [From]}),
                            schedule_key_eval(F, Key, self());
                        [{_Key, WaiterPids}] ->
                            ets:insert(Pending, {Key, [From | WaiterPids]})
                    end;
                [{Key, Value}] ->
                    From ! {self(), Value}
            end,
            loop(S);
        {key_eval_succeeded, Key, Value} ->
            true = ets:insert_new(Cached, {Key, Value}),
            notify_waiting_getters(Pending, Key, Value),
            loop(S);
        {key_eval_failed, Key, Reason} ->
            notify_waiting_getters(Pending, Key, Reason),
            loop(S)
    end.

schedule_key_eval(F, Key, ReplyTo) ->
    _Pid = spawn(fun() ->
        io:format("Evaluating function at ~w~n", [Key]),
        try F(Key) of
            Value ->
                io:format("Evaluated ~w to ~w~n", [Key, Value]),
                ReplyTo ! {key_eval_succeeded, Key, Value}
        catch
            _Class:Reason:_Stacktrace ->
                io:format("Failed to evaluate ~w due to ~w~n", [Key, Reason]),
                ReplyTo ! {key_eval_failed, Key, Reason}
        end
    end).

notify_waiting_getters(Pending, Key, Value) ->
    [{_Key, WaiterPids}] = ets:lookup(Pending, Key),
    ets:delete(Pending, Key),
    foreach(fun(Pid) -> Pid ! {self(), Value} end, reverse(WaiterPids)).
