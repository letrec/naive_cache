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
        [{Key, Value}] ->
            io:format("Value for ~w is in the cache~n", [Key]),
            Value;
        [] ->
            io:format("Value for ~w is not in the cache~n", [Key]),
            Server ! {self(), {get, Key}},
            receive
                {Server, Value} -> Value
            end
    end.

loop({F, Cached, Pending} = S) ->
    receive
        stop ->
            ok;
        {From, {get, Key}} ->
            case ets:lookup(Cached, Key) of
                [{Key, Value}] ->
                    From ! {self(), Value};
                [] ->
                    case ets:lookup(Pending, Key) of
                        [{Key, WaiterPids}] ->
                            true = ets:insert(Pending, {Key, [From | WaiterPids]});
                        [] ->
                            Server = self(),
                            spawn(fun() ->
                                io:format("Evaluating function at ~w~n", [Key]),
                                try F(Key) of
                                    Value ->
                                        io:format("Evaluated ~w to ~w~n", [Key, Value]),
                                        Server ! {getOk, Key, Value}
                                catch
                                    _Class:Reason:_Stacktrace ->
                                        io:format("Failed to evaluate ~w due to ~w~n", [Key, Reason]),
                                        Server ! {getError, Key, Reason}
                                end
                            end),
                            true = ets:insert_new(Pending, {Key, [From]})
                    end
            end,
            loop(S);
        {getOk, Key, Value} ->
            true = ets:insert_new(Cached, {Key, Value}),
            [{_Key, WaiterPids}] = ets:lookup(Pending, Key),
            ets:delete(Pending, Key),
            foreach(fun(Pid) -> Pid ! {self(), Value} end, reverse(WaiterPids)),
            loop(S);
        {getError, Key, Reason} ->
            [{_Key, WaiterPids}] = ets:lookup(Pending, Key),
            ets:delete(Pending, Key),
            foreach(fun(Pid) -> Pid ! {self(), Reason} end, reverse(WaiterPids)),
            loop(S)
    end.
