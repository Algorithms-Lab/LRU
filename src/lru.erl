-module('lru').
-author('VSolenkov').

-behaviour('gen_statem').

-export([
    start_link/0
]).
-export([
    point/1,
    cheat/1,
    count/1,
    state/0,
    store/0,
    fetch/0,
    clean/0,
    clean/1,
    clean/2
]).
-export([
    reset/1
]).
-export([
    init/1,
    callback_mode/0
]).
-export([
    common/3,
    delete/3
]).
-include("include/lru.hrl").



start_link() ->
    gen_statem:start_link(
        {local,?MODULE},
        ?MODULE,[0,0,0],
    [{spawn_opt,?SPAWN_OPT_LRU}]).



init([_,_,_]) ->
    [O,C,Q] = restorage(?ETS_KEYS_STORE_TABLE_NAME),
    {ok,common,[O,C,Q]}.

callback_mode() ->
    state_functions.


point(K) ->
    case lru_utils:key_validation(K) of
        BK when is_binary(BK) ->
            gen_statem:cast(?MODULE,{point,BK});
        -1 ->
            "type_error";
        -2 ->
            "size_key_error"
    end.
cheat(KVL) ->
    case is_list(KVL) of
        true ->
            VKVL = lists:filtermap(
                fun({K,V}) ->
                    case lru_utils:key_validation(K) of
                        BK when is_binary(BK) ->
                            {true,{BK,V}};
                        _ ->
                            false
                    end
                end,
            KVL),
            if
                length(VKVL) > 0 ->
                    gen_statem:cast(?MODULE,{cheat,VKVL});
                true ->
                    "data_error"
            end;
        false ->
            "type_error"
    end.
count(K) ->
    case lru_utils:key_validation(K) of
        BK when is_binary(BK) ->
            gen_statem:call(?MODULE,{count,BK});
        -1 ->
            "type_error";
        -2 ->
            "size_key_error"
    end.
state() ->
    gen_statem:call(?MODULE,state).
store() ->
    gen_statem:cast(?MODULE,store).
fetch() ->
    gen_statem:call(?MODULE,fetch).
clean() ->
    gen_statem:call(?MODULE,{clean,async}).
clean(async) ->
    gen_statem:call(?MODULE,{clean,async});
clean(sync) ->
    gen_statem:call(?MODULE,{clean,sync}).

clean(R,K) ->
    gen_statem:cast(?MODULE,{{clean,R},K}).

reset(D) ->
    gen_statem:cast(?MODULE,{reset,D}).


common(cast,{point,K},[O,C,Q]) ->
    [NO,NC,NQ] = point_handler(K,O,C,Q),
    {keep_state,[NO,NC,NQ]};
common(cast,{cheat,KVL},[O,C,Q]) ->
    [NO,NC,NQ] = cheat_handler(KVL,O,C,Q),
    {keep_state,[NO,NC,NQ]};
common(cast,store,[O,C,Q]) ->
    lru_utils:ets_reset([?ETS_KEYS_STORE_TABLE_NAME]),
    {keep_state,[O,C,Q]};
common(cast,{reset,D},[O,C,Q]) ->
    [NO,NC,NQ] = reset_handler(D,O,C,Q),
    {keep_state,[NO,NC,NQ]};
common({call,F},{count,K},[O,C,Q]) ->
    {keep_state,[O,C,Q],[{reply,F,get(K)}]};
common({call,F},state,[O,C,Q]) ->
    {keep_state,[O,C,Q],[{reply,F,[O,C,Q]}]};
common({call,F},fetch,[O,C,Q]) ->
    {keep_state,[O,C,Q],[{reply,F,fetch_handler(O,Q)}]};
common({call,F},{clean,async},[O,C,Q]) ->
    {next_state,delete,[O,C,Q,#{from => F}],[{next_event,internal,clean}]};
common({call,F},{clean,sync},[O,C,Q]) ->
    K = fetch_handler(O,Q),
    R = make_ref(),
    {next_state,delete,[O,C,Q,#{key => K, ref => R}],[{reply,F,{K,R}},{state_timeout,?TIMEOUT_STATE_DELETE,K}]};
common(cast,{{clean,_R},_K},_StateData) ->
    keep_state_and_data;
common(cast,EventContent,_StateData) ->
    io:format('State: common~nEventType: cast~nEventContent: ~p~n',[EventContent]),
    keep_state_and_data;
common({call,_F},EventContent,_StateData) ->
    io:format('State: common~nEventType: cast~nEventContent: ~p~n',[EventContent]),
    keep_state_and_data;
common(info,_EventContent,_StateData) ->
    keep_state_and_data.

delete(internal,clean,[O,C,Q,#{from := F}]) ->
    [K,NO,NC,NQ] = clean_handler(O,C,Q),
    {next_state,common,[NO,NC,NQ],[{reply,F,K}]};
delete(state_timeout,K,[O,C,Q,#{key := K, ref := _}]) ->
    {next_state,common,[O,C,Q]};
delete(cast,{{clean,R},K},[O,C,Q,#{key := K, ref := R}]) ->
    [K,NO,NC,NQ] = clean_handler(O,C,Q),
    {next_state,common,[NO,NC,NQ]};
delete(cast,{{clean,_R},_K},_StateData) ->
    keep_state_and_data;
delete(cast,{point,_K},_StateData) ->
    {keep_state_and_data,[postpone]};
delete(cast,{cheat,_KVL},_StateData) ->
    {keep_state_and_data,[postpone]};
delete(cast,store,_StateData) ->
    {keep_state_and_data,[postpone]};
delete(cast,reset,_StateData) ->
    {keep_state_and_data,[postpone]};
delete({call,_F},{count,_K},_StateData) ->
    {keep_state_and_data,[postpone]};
delete({call,_F},state,_StateData) ->
    {keep_state_and_data,[postpone]};
delete({call,_F},fetch,_StateData) ->
    {keep_state_and_data,[postpone]};
delete({call,_F},{clean,async},_StateData) ->
    {keep_state_and_data,[postpone]};
delete({call,_F},{clean,sync},_StateData) ->
    {keep_state_and_data,[postpone]};
delete(cast,_EventContent,_StateData) ->
    keep_state_and_data;
delete({call,_F},_EventContent,_StateData) ->
    keep_state_and_data;
delete(info,_EventContent,_StateData) ->
    keep_state_and_data.


point_handler(K,O,C,Q) ->
    if
        C =< ?MAX_COUNTER ->
            [NO,NC,NQ] =
            if
                C rem ?SERIE_SIZE == 0 ->
                    case get(K) of
                        undefined ->
                            put(K,C+1),
                            put(C div ?SERIE_SIZE,<<"1">>),
                            ets:insert(?ETS_KEYS_STORE_TABLE_NAME,{K,C+1}),
                            [if Q == 0 -> C+1; true -> O end,C+1,Q+1];
                        OC ->
                            case get((OC-1) div ?SERIE_SIZE) of
                                <<"1">> -> erase((OC-1) div ?SERIE_SIZE);
                                QS -> put((OC-1) div ?SERIE_SIZE,integer_to_binary(binary_to_integer(QS)-1))
                            end,
                            put(K,C+1),
                            put(C div ?SERIE_SIZE,<<"1">>),
                            ets:insert(?ETS_KEYS_STORE_TABLE_NAME,{K,C+1}),
                            if
                                OC == O ->
                                    [compute_oldest_key((O-1) div ?SERIE_SIZE,C div ?SERIE_SIZE),C+1,Q];
                                true ->
			            [O,C+1,Q]
                            end
                    end;
                true ->
                    get(C div ?SERIE_SIZE) =:= undefined andalso put(C div ?SERIE_SIZE,<<"0">>),

                    case get(K) of
                        undefined ->
                            put(K,C+1),
                            put(C div ?SERIE_SIZE,integer_to_binary(binary_to_integer(get(C div ?SERIE_SIZE))+1)),
                            ets:insert(?ETS_KEYS_STORE_TABLE_NAME,{K,C+1}),
                            [O,C+1,Q+1];
                        OC ->
                            put(K,C+1),
                            (OC-1) div ?SERIE_SIZE /= C div ?SERIE_SIZE andalso
                            case get((OC-1) div ?SERIE_SIZE) of
                                <<"1">> -> erase((OC-1) div ?SERIE_SIZE),true;
                                QS -> put((OC-1) div ?SERIE_SIZE,integer_to_binary(binary_to_integer(QS)-1)),true
                            end andalso put(C div ?SERIE_SIZE,integer_to_binary(binary_to_integer(get(C div ?SERIE_SIZE)) + 1)),
                            ets:insert(?ETS_KEYS_STORE_TABLE_NAME,{K,C+1}),
                            if
                                OC == O ->
                                    [compute_oldest_key((O-1) div ?SERIE_SIZE,(C-1) div ?SERIE_SIZE),C+1,Q];
                                true ->
			            [O,C+1,Q]
                            end
                    end
            end,
            ?SUPPORT andalso erlang:apply(?AUXILIARY,point,[K]),
            [NO,NC,NQ];
        true ->
            ?SUPPORT andalso erlang:apply(?AUXILIARY,point,[K]),
            [O,C,Q]
    end.

cheat_handler(KVL,O,C,Q) ->
    [NO,NC,NQ] = lists:foldl(
        fun({K,V},[NO,NC,NQ]) when V =< ?MAX_COUNTER ->
            case get(K) of
                undefined ->
                    if
                        V > 0 ->
                            put(K,V),
                            put((V-1) div ?SERIE_SIZE,
                                case get((V-1) div ?SERIE_SIZE) of
                                    undefined -> <<"1">>;
                                    QS -> integer_to_binary(binary_to_integer(QS) + 1)
                                end
                            ),
                            ets:insert(?ETS_KEYS_STORE_TABLE_NAME,{K,V}),
                            if
                                NQ == 0 ->
                                    [V,V,1];
                                NC < V ->
				    [NO,V,NQ+1];
                                NO > V ->
                                    [V,NC,NQ+1];
                                true ->
                                    [NO,NC,NQ+1]
                            end;
                        true ->
                            [NO,NC,NQ]
                    end;
                OV ->
                    if
                        V > 0 ->
                            put(K,V),
                            get((V-1) div ?SERIE_SIZE) /= get((OV-1) div ?SERIE_SIZE) andalso
                            case get((OV-1) div ?SERIE_SIZE) of
                                <<"1">> -> erase((OV-1) div ?SERIE_SIZE),true;
                                QS1 -> put((OV-1) div ?SERIE_SIZE,integer_to_binary(binary_to_integer(QS1)-1)),true
                            end andalso
                            case get((V-1) div ?SERIE_SIZE) of
                                undefined -> put((V-1) div ?SERIE_SIZE,<<"1">>);
                                QS2 -> put((V-1) div ?SERIE_SIZE,integer_to_binary(binary_to_integer(QS2)-1))
                            end,
                            ets:insert(?ETS_KEYS_STORE_TABLE_NAME,{K,V}),
                            if
                                NC < V ->
                                    if
                                        NO == OV ->
                                            [compute_oldest_key((OV-1) div ?SERIE_SIZE,(V-1) div ?SERIE_SIZE),V,NQ];
                                        true ->
                                            [NO,V,NQ]
                                    end;
                                NO > V ->
                                    [V,NC,NQ];
                                NO == OV ->
                                    [compute_oldest_key((OV-1) div ?SERIE_SIZE,(NC-1) div ?SERIE_SIZE),NC,NQ];
                                true ->
                                    [NO,NC,NQ]
                            end;
                        true ->
                            erase(K),
                            case get((OV-1) div ?SERIE_SIZE) of
                                <<"1">> -> erase((OV-1) div ?SERIE_SIZE);
                                QS3 -> put((OV-1) div ?SERIE_SIZE,integer_to_binary(binary_to_integer(QS3)-1))
                            end,
                            ets:delete(?ETS_KEYS_STORE_TABLE_NAME,K),
                            if
                                NO == OV ->
                                    [compute_oldest_key((OV-1) div ?SERIE_SIZE,(NC-1) div ?SERIE_SIZE),NC,NQ-1];
                                true ->
                                    [NO,NC,NQ-1]
                            end
                    end
            end;
        (_,[NO,NC,NQ]) ->
            [NO,NC,NQ]
        end,
    [O,C,Q],KVL),
    [NO,if NQ == 0 -> 0; true -> NC end,NQ].

fetch_handler(O,Q) ->
    if
        Q =:= 0 ->
            {O,[]};								%% that is: {0,[]};
        true ->
            [K|_] = get_keys(O),						%% in case if command 'cheat' sets duplicate counters for different keys
            {O,[K]}
    end.

clean_handler(O,C,Q) ->
    if
        Q =:= 0 ->
            [{O,[]},O,C,Q];							%% that is: [{0,[]},0,0,0];
        true ->
            [K|_] = get_keys(O),						%% in case if command 'cheat' sets duplicate counters for different keys
            erase(K),
            case get((O-1) div ?SERIE_SIZE) of
                <<"1">> -> erase((O-1) div ?SERIE_SIZE);
                QS -> put((O-1) div ?SERIE_SIZE,integer_to_binary(binary_to_integer(QS)-1))
            end,
            ets:delete(?ETS_KEYS_STORE_TABLE_NAME,K),
            ?SUPPORT andalso erlang:apply(?AUXILIARY,reset,[[{O,[K]}]]),
            [
                {O,[K]},
                compute_oldest_key((O-1) div ?SERIE_SIZE,(C-1) div ?SERIE_SIZE),
                if
                    Q-1 == 0 -> 0;
                    true -> C
                end,
                Q-1
            ]
    end.

reset_handler({_,KL},O,C,Q) ->
    [NO,NQ] = lists:fold1(
        fun(K,[NO,NQ]) ->
            case erase(K) of
                undefined -> [NO,NQ];
                OC ->
                    case get((OC-1) div ?SERIE_SIZE) of
                        <<"1">> -> erase((OC-1) div ?SERIE_SIZE);
                        QS -> put((OC-1) div ?SERIE_SIZE,integer_to_binary(binary_to_integer(QS)-1))
                    end,
                    ets:delete(?ETS_KEYS_STORE_TABLE_NAME,K),
                    if
                        OC == O ->
                            [compute_oldest_key((OC-1) div ?SERIE_SIZE,(C-1) div ?SERIE_SIZE),NQ-1];
                        true ->
                            [NO,NQ-1]
                    end
            end
        end,
    [O,Q],KL),
    [NO,if NQ == 0 -> 0; true -> C end,NQ];
reset_handler(T,O,C,Q) ->
    [NO,NQ] = case ets:info(T) of
        undefined -> [O,Q];
        _ ->
            ets:foldl(
                fun({_,KL},[NO,NQ]) ->
                    lists:foldl(
                        fun(K,[NO,NQ]) ->
                            case erase(K) of
                                undefined -> [NO,NQ];
                                OC ->
                                    case get((OC-1) div ?SERIE_SIZE) of
                                        <<"1">> -> erase((OC-1) div ?SERIE_SIZE);
                                        QS -> put((OC-1) div ?SERIE_SIZE,integer_to_binary(binary_to_integer(QS)-1))
                                    end,
                                    ets:delete(?ETS_KEYS_STORE_TABLE_NAME,K),
                                    if
                                        OC == O ->
                                            [compute_oldest_key((OC-1) div ?SERIE_SIZE,(C-1) div ?SERIE_SIZE),NQ-1];
                                        true ->
                                            [NO,NQ-1]
                                    end
                            end
                        end,
                    [NO,NQ],KL)
                end,
            [O,Q],T)
    end,
    [NO,if NQ == 0 -> 0; true -> C end,NQ].


compute_oldest_key(U,U) ->
    case get(U) of
        undefined -> 0;
        _ -> check_keys_serie((U*?SERIE_SIZE)+1,(U+1)*?SERIE_SIZE)
    end;
compute_oldest_key(L,U) ->
    case get(L) of
        undefined -> compute_oldest_key(L+1,U);
        _ -> check_keys_serie((L*?SERIE_SIZE)+1,(L+1)*?SERIE_SIZE)
    end.

check_keys_serie(U,U) ->
    case get_keys(U) of
        [] -> 0;
        [_|_] -> U								%% in case if command 'cheat' sets duplicate counters for different keys
    end;
check_keys_serie(L,U) ->
    case get_keys(L) of
        [] -> check_keys_serie(L+1,U);
        [_|_] -> L								%% in case if command 'cheat' sets duplicate counters for different keys
    end.


restorage(T) ->
    case ets:whereis(T) of
        undefined -> [0,0,0];
        _ ->
            ets:foldl(
                fun({K,C},[NO,NC,NQ]) ->
                    if
                        C =< ?MAX_COUNTER andalso C > 0 ->
                            QS = get((C-1) div ?SERIE_SIZE),
                            put((C-1) div ?SERIE_SIZE,
                                if
                                    QS == undefined -> <<"1">>;
                                    true -> integer_to_binary(binary_to_integer(QS) + 1)
                                end
                            ),
                            put(K,C),
                            if
                                NQ == 0 ->
                                    [C,C,1];
                                C < NO ->
                                    [C,NC,NQ+1];
                                C > NC ->
                                    [NO,C,NQ+1];
                                true ->
                                    [NO,NC,NQ+1]
                            end;
                        true ->
                            [NO,NC,NQ]
                    end
                end,
            [0,0,0],T)
    end.
