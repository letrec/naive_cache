-module(naive_cache).
-author("https://github.com/letrec").

-import(erlang, [
    monotonic_time/0
]).

-import(lists, [
    foldr/3,
    foreach/2,
    reverse/1
]).

-export([
    start/1,
    stop/1,
    init/2,
    get/2
]).

-record(naive_cache_ref, {
    server :: pid(),
    table :: ets:tid()
}).

-opaque naive_cache_ref() :: #naive_cache_ref{}.
-export_type([naive_cache_ref/0]).

-record(state, {
    f :: fun((any()) -> any()),
    cached :: ets:tid(),
    pending :: ets:tid()
}).

-type state() :: #state{}.

-define(hit_ix, 1).
-define(miss_ix, 2).
-define(eval_time_ix, 3).
-define(counters_size, 3).

-spec start(F :: fun((any()) -> any())) -> naive_cache_ref().
start(F) ->
    Pid = spawn(?MODULE, init, [self(), F]),
    receive
        {Pid, {?MODULE, Table}} -> #naive_cache_ref{server = Pid, table = Table}
    end.

-spec stop(Ref :: naive_cache_ref()) -> ok.
stop(#naive_cache_ref{server = Pid}) ->
    Pid ! stop,
    ok.

-spec init(From :: pid(), F :: fun()) -> none().
init(From, F) ->
    Cached = ets:new(cached, [set, protected, {read_concurrency, true}]),
    Pending = ets:new(pending, [set, private]),

    From ! {self(), {?MODULE, Cached}},

    loop(#state{f = F, cached = Cached, pending = Pending}).

-spec get(Ref :: naive_cache_ref(), Key :: any()) -> any().
get(#naive_cache_ref{server = Server, table = Table}, Key) ->
    case ets:lookup(Table, Key) of
        [] ->
            Server ! {self(), {eval_key, Key}},
            receive
                {Server, Value} -> Value
            end;
        [{Key, Value, Counters}] ->
            counters:add(Counters, ?hit_ix, 1),
            Value
    end.

-spec loop(State :: state()) -> ok | no_return().
loop(#state{f = F, cached = Cached, pending = Pending} = S) ->
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
                            eval_key_async(F, Key, self());
                        [{_Key, WaiterPids}] ->
                            ets:insert(Pending, {Key, [From | WaiterPids]})
                    end;
                [{Key, Value, Counters}] ->
                    atomics:add(Counters, ?hit_ix, 1),
                    From ! {self(), Value}
            end,
            loop(S);
        {key_eval_succeeded, Key, Value, EvalTime} ->
            Counters = counters:new(?counters_size, [write_concurrency]),
            counters:add(Counters, ?eval_time_ix, EvalTime),

            true = ets:insert_new(Cached, {Key, Value, Counters}),

            WaiterCount = notify_waiting_getters(Pending, Key, Value),
            counters:add(Counters, ?miss_ix, WaiterCount),

            loop(S);
        {key_eval_failed, Key, Reason} ->
            notify_waiting_getters(Pending, Key, Reason),
            loop(S)
    end.

-spec eval_key_async(F :: fun(), Key :: any(), ReplyTo :: pid()) -> ok.
eval_key_async(F, Key, ReplyTo) ->
    _Pid = spawn(fun() ->
        Start = monotonic_time(),
        try F(Key) of
            Value    -> ReplyTo ! {key_eval_succeeded, Key, Value, monotonic_time() - Start}
        catch
            _:Reason -> ReplyTo ! {key_eval_failed, Key, Reason}
        end
    end),
    ok.

-spec notify_waiting_getters(Pending :: ets:tid(), Key :: any(), Value :: any()) -> integer().
notify_waiting_getters(Pending, Key, Value) ->
    [{_Key, WaiterPids}] = ets:lookup(Pending, Key),
    ets:delete(Pending, Key),
    foldr(
        fun(Pid, Count) ->
            Pid ! {self(), Value},
            Count + 1
        end,
        0,
        reverse(WaiterPids)).
