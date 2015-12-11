%%% ----------------------------------------------------------------------------
%%% @author Jim Rosenblum <jrosenblum@prodigy.net>
%%% @copyright (C) 2015, Jim Rosenblum
%%% @doc
%%% The jwalk module is intended to make it easier to work with Erlang encodings
%%% of JSON - either Maps, Proplists or eep18-style representations.
%%%
%%% This work is inspired by [https://github.com/seth/ej], but it handles 
%%% maps, proplists and eep18 representations of JSON but not mochijson's 
%%% struct/tuple encodings.
%%%
%%% Functions always take at least two parameters: a first parameter which is a
%%% tuple of elements representing a Path into a JSON Object, and a second 
%%% parameter which is expected to be a proplist, map or eep18 representation 
%%% of a JSON structure.
%%%
%%% The Path components of the first parameter are a tuple representation of 
%%% a javascript-like path: i.e., 
%%%
%%% Obj.cars.make.model would be expressed as {"cars","make","model"}
%%%
%%% Path components may also contain:
%%%
%%% The atoms `` 'first' '' and `` 'last' '' or an integer index indicating an 
%%% element from a JSON Array; or,
%%%
%%% {`select', {"name","value"}} which will return a subset of JSON objects in 
%%% an Array that have a {"name":"value"} Member. 
%%%
%%% `new': for set/2 and set_p/2, when the final element of a path is the atom 
%%% `new', the supplied value is added to the stucture as the first element of
%%% an array, the array is created if necessary.
%%%
%%% Path, string elements can be binary or not
%%%
%%% ```
%%% Cars = {[{<<"cars">>, [ {[{<<"color">>, <<"white">>}, {<<"age">>, <<"old">>}]},
%%%                         {[{<<"color">>, <<"red">>},  {<<"age">>, <<"old">>}]},
%%%                         {[{<<"color">>, <<"blue">>}, {<<"age">>, <<"new">>}]}
%%%                       ] }]}.
%%% '''
%%% Then 
%%%
%%% ```
%%% jwalk:get({"cars", {select, {"age", "old"}}}, Cars).
%%%
%%% [ {[{<<"color">>,<<"white">>},{<<"age">>,<<"old">>}]},
%%%   {[{<<"color">>,<<"red">>},{<<"age">>,<<"old">>}]} ]
%%%
%%% jwalk:get({"cars", {select, {"age", "old"}}, 1}, Cars).
%%% {[{<<"color">>,<<"white">>},{<<"age">>,<<"old">>}]}
%%%
%%% jwalk:get({"cars", {select, {"age", "old"}},first,"color"}, Cars).
%%% <<"white">>
%%% '''
%%% @end
%%% Created : 20 Nov 2015 by Jim Rosenblum <jrosenblum@prodigy.net>
%%% ----------------------------------------------------------------------------
-module(jwalk).

-export([delete/2,
         get/2, get/3,
         set/3, 
         set_p/3]).


-define(IS_EEP(X),  (X == [{}] orelse 
                     is_tuple(X) andalso 
                     is_list(element(1, X)) andalso 
                     (hd(element(1,X)) == {} orelse 
                     tuple_size(hd(element(1,X))) == 2))).

-define(IS_PL(X), (X == {[]} orelse 
                   (is_list(X) andalso is_tuple(hd(X)) andalso
                   (tuple_size(hd(X)) == 0 orelse tuple_size(hd(X)) == 2)))).

-define(IS_OBJ(X), (is_map(X) orelse ?IS_PL(X) orelse ?IS_EEP(X))).
-define(EMPTY_STRUCT(X), (X == [{}] orelse X == {[]})).
-define(EMPTY_OBJ(X), (X == [{}] orelse X == {[]} orelse X == #{})).
-define(NOT_MAP_OBJ(X), (not is_map(X)) andalso ?IS_OBJ(X)).

-define(IS_J_TERM(X), 
        (?IS_OBJ(X) orelse 
        is_number(X) orelse 
        (X == true) orelse
        (X == false) orelse 
        is_binary(X) orelse
        (X == null))).

-define(IS_SELECTOR(K), 
        ((K == first) orelse
         (K == last) orelse 
         (K == new) orelse
         is_integer(K) orelse
         (is_tuple(K) andalso (element(1, K) == select)))).

-define(IS_INDEX(K), 
        (K == first) orelse
        (K == last) orelse 
        is_integer(K)).

-define(NOT_SELECTOR(K), (not ?IS_SELECTOR(K))).


% Types
-type name()     :: binary() | string().
-type value()    :: binary() | string() | number() | 
                    delete | true | false | null| integer().

-type select()   :: {select, {name(), value()}}.
-type p_index()  :: 'first' | 'last' | non_neg_integer().
-type p_elt()    :: name() | select() | p_index() | 'new'.
-type path()     :: {p_elt()} | [p_elt(),...].

-type pl()     :: [{}] | [{name(), value()  | pl() | [pl()]},...].
-type eep()    :: {[]} | {[{name(), value() | eep() | [eep(),...]}]}.
-type obj()    :: map() | pl() | eep() | [pl(),...] | [eep(),...] | [map(),...].

-type obj_type() :: map | proplist | eep.

-type jwalk_return() :: undefined | obj() | value() | 
                       [undefined | obj() | value(),...].

-export_type ([jwalk_return/0]).



%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------


%% -----------------------------------------------------------------------------
%% @doc Remove the value at the location specified by `Path' and return the
%% new representation. 
%%
%% Path elements that are strings can be binary or not - they are converted to 
%% binary if not. 
%%
%% Throws <br/>
%% {no_path, _} <br/>
%% {selector_used_on_object, _} <br/>
%% {selector_used_on_non_array, _, _} <br/>
%% {index_for_non_array, _} <br/>
%% {replacing_object_with_value, _} <br/>
%% {index_out_of_bounds, _, _}.
%%
-spec delete(path(), obj()) -> jwalk_return().

delete(Path, Obj) ->
    case rep_type(Obj) of
        error ->
            error({illegal_object, Obj});
        Type ->
            do_set(to_binary_list(Path), Obj, delete, [], false, Type)
    end.

    
%% -----------------------------------------------------------------------------
%% @doc Return a value from an `Obj'. 
%%
%% Path elements that are strings can be binary or not - they are converted to
%% binary if not.
%%
%% Throws <br/>
%% {selector_used_on_object, _} <br/>
%% {index_for_non_array, _} <br/>
%%
-spec get(path(), obj()) -> jwalk_return().

get(Path, Obj) ->
    try 
        walk(to_binary_list(Path), Obj)
    catch
        throw:Error ->
            error(Error)
    end.


%% -----------------------------------------------------------------------------
%% @doc Return a value from an `Obj' or Default if value not found. 
%%
%% Path elements that are strings can be binary or not - they are converted to
%% binary if not.
%%
%% See {@link get/2. get/2}.
%%
-spec get(path(), obj(), Default::any()) -> jwalk_return().

get(Path, Obj, Default) ->
    case get(Path, Obj) of
        undefined ->
            Default;
        Found ->
            Found
    end.


%% -----------------------------------------------------------------------------
%% @doc Set a value in `Obj'.
%%
%% Replace the value at the specified `Path' with `Value' and return the new
%% structure. If the final element of the Path does not exist, create it.
%%
%% The atom, `new', applied to an ARRAY, will make the Value the first Element 
%% in an Array, creating that Array if necessary.
%%
%% Path elements that are strings can be binary or not - they are converted to
%% binary if not.
%%
%% Throws <br/>
%% {no_path, _} <br/>
%% {selector_used_on_object, _} <br/>
%% {selector_used_on_non_array, _, _} <br/>
%% {index_for_non_array, _} <br/>
%% {replacing_object_with_value, _} <br/>
%% {index_out_of_bounds, _, _}.
%%
-spec set(path(), obj(), value()) -> jwalk_return().

set(Path, Obj, Value) ->
    case rep_type(Obj) of
        error ->
            error({illegal_object, Obj});
        Type ->
            do_set(to_binary_list(Path), Obj, Value, [], false, Type)
    end.


%% -----------------------------------------------------------------------------
%% @doc Same as {@link set/3. set/3} but creates intermediary elements as 
%% necessary. 
%%
-spec set_p(path(), obj(), value()) -> jwalk_return().

set_p(Path, Obj, Value) ->
    case rep_type(Obj) of
        error ->
            error({illegal_object, Obj});
        Type ->
            do_set(to_binary_list(Path), Obj, Value, [], true, Type)
    end.


-spec do_set(path(), obj(), value(), [tuple()], boolean(), obj_type()) -> 
                                                                 jwalk_return().
do_set(Path, Obj, Value, Acc, P, RepType) ->
    try 
        set_(Path, Obj, Value, Acc, P, RepType)
    catch
        throw:Error ->
            error(Error)
    end.



%% -----------------------------------------------------------------------------
%%                WALK and SET_ INTERNAL FUNCTIONS
%% -----------------------------------------------------------------------------


-spec walk(path(), obj()|[]) -> jwalk_return().

% Some base cases.
walk([{select, {_,_}}|_], []) ->  [];

walk([], _)   -> undefined;

walk(_, [])   -> undefined;

walk(_, null) -> undefined;

walk([{select, {_, _}}|_], Obj) when ?IS_OBJ(Obj) ->
    throw({selector_used_on_object, Obj});

walk([S|_], Obj) when ?IS_OBJ(Obj), ?IS_INDEX(S) -> 
    throw({index_for_non_array, Obj});

walk([Name|Path], Obj) when ?IS_OBJ(Obj) -> 
    continue(get_member(Name, Obj), Path);

walk([S|Path], {[_|_]=Array}) ->
    walk([S|Path], Array);

% ARRAY with a Selector/Index: continue with selected subset.
walk([{select, {_,_}}=S|Path], [_|_]=Array) ->
    continue(subset_from_selector(S, Array), Path);

walk([S|Path], [_|_]=Array) when ?IS_INDEX(S) ->
    continue(nth(S, Array), Path);

% ARRAY with a Member Name: continue with the values from the Objects in the
% Array that have Member = {Name, Value}.
walk([Name|Path], [_|_]=Array) ->
    continue(values_from_member(Name, Array), Path);

% Element is something other than an ARRAY, but we have a selector.
walk([S|_], Element) when ?IS_SELECTOR(S) ->
    case S of
        {select, {_,_}} ->
            throw({selector_for_non_array, Element});
        _ ->
            throw({index_for_non_array, Element})
    end.


continue(false, _Path)                         -> undefined;
continue(undefined, _Path)                     -> undefined;
continue({_Name, Value}, Path) when Path == [] -> Value;
continue(Value, Path) when Path == []          ->  Value;
continue({_Name, Value}, Path)                 -> walk(Path, Value);
continue(Value, Path)                          -> walk(Path, Value).



-spec set_(path(), obj()|[], term(), [tuple()], boolean(), obj_type()) -> 
                                                                 jwalk_return().

% Final Path element: DELETE.
set_([Name], Obj, delete, _Acc, _IsP, _RType) when ?IS_OBJ(Obj) andalso
                                                          ?NOT_SELECTOR(Name) ->
    delete_member(Name, Obj);

set_([S], [_|_]=Array, delete, _Acc, _IsP, _RType) when ?IS_INDEX(S)->
    remove(Array, nth(S, Array));

set_([{select, {_,_}}=S], [_|_]=Array, delete, _Acc, _IsP, _RType) ->
    remove(Array, subset_from_selector(S, Array));

% Final Path element: remove Objects from Array with Member whose name = Name.
set_([Name], [_|_]=Array, delete, _Acc, _IsP, _RType) ->
    [delete_member(Name, O) || O <- Array, ?IS_OBJ(O)];


% Final Path element: if it exists in the OBJECT replace or create it.
set_([Name], Obj, Val, _Acc, _IsP, _RType) when ?IS_OBJ(Obj) andalso
                                                          ?NOT_SELECTOR(Name) ->
    add_member(Name, Val, Obj);


% Members applied to an empty object, if set_p, create it and move on
set_([Name|Ps], Obj, Val, _Acc, true, RType) when ?EMPTY_STRUCT(Obj),
                                                          ?NOT_SELECTOR(Name) ->
    eep_or_pl(RType, 
              [{Name, set_(Ps, empty(RType), Val, [], true, RType)}]);


% Iterate Members for one w/ name=Name. Replace value with recur call if found.
set_([Name|Ps]=Path, Obj, Val, Acc, IsP, RType) when ?NOT_MAP_OBJ(Obj), ?NOT_SELECTOR(Name) ->
    {N,V,Ms} = normalize_members(Obj), % first member Name, Value and rest of Members
    case Name of
        N ->
            NewVal = set_(Ps, V, Val, [], IsP, RType),
            eep_or_pl(RType,
                      lists:append(lists:reverse(Acc),[{N, NewVal}|Ms]));
        _Other when Ms /= [] ->
            set_(Path, Ms, Val, [{N,V}|Acc], IsP, RType);
        _Other when Ms == [], IsP == true->
            lists:append(lists:reverse(Acc), [{N,V},  {Name, set_(Ps, empty(RType), Val, [], IsP, RType)}]);
        _Other when Ms == []  -> 
            throw({no_path, Name})
    end;

% map case, 
set_([Name|Ps], Map, Val, _Acc, P, map) when is_map(Map), ?NOT_SELECTOR(Name) ->
    case map_get(Name, Map, not_found) of
        not_found -> 
            case P of
                true ->
                    maps:put(Name, set_(Ps, #{}, Val, [], P, map), Map);
                _ -> 
                    throw({no_path, Name})
            end;
        Value -> 
            maps:put(Name, set_(Ps, Value, Val, [], P, map), Map)
    end;

% When final Path elemenet is NEW applied to empty object, return Value in Array
set_([new], Obj, Val, _Acc, _P, _RType) when ?IS_J_TERM(Val), ?EMPTY_OBJ(Obj) ->
    [Val];
    
% Select_by_member applied to an empty Object. 
set_([{select,{K,V}}=S|Ks], Obj, Val, _Acc, P, RType) when ?EMPTY_OBJ(Obj) ->
    Object = case P of
                 true ->
                     [add_member(K, V, empty(RType))];
                  false -> 
                    throw({no_path, S})
              end,
    set_(Ks, Object, Val, [], P, RType);

set_([S|_], Obj, _V, _A, _P, _IsMap) when ?IS_SELECTOR(S) andalso ?IS_OBJ(Obj)-> 
    throw({selector_used_on_object, S, Obj});
    
% ALL OBJECT CASES HANDLED ABOVE %

% New applied to an ARRAY creates Value as the first element in  Array.
set_([new], [_|_]=Array, Val, _Acc, _P, _RType) ->
    [Val|Array];


% Final Path element is 'select by member' applied to ARRAY. Set / replace the 
% selected Objects with the Value
set_([{select,{_,_}}=S], {[_|_]=Array}, Val, Acc, P, RType) when ?IS_OBJ(Val) ->
    set_([S], Array, Val, Acc, P, RType);

set_([{select,{K,V}}=S], [_|_]=Array, Val, _Acc, _P, RType) when ?IS_OBJ(Val) ->
    Found = subset_from_selector(S, Array),
    Replace = case Found of
                  [] -> 
                      merge_members([add_member(K, V, empty(RType))], Val);
                  Found -> 
                      merge_members(Found, Val)
              end,
    replace_object(Array, Found, Replace);


set_([{select,{_,_}}], _Array, Val, _Acc, _P, _RType) -> 
    throw({replacing_object_with_value, Val});


% Intermediate Path element is a Select_by_member applied to an ARRAY. 
set_([{select,{K,V}}=S|Ks], Array, Val, _Acc, P, RType) ->
    Found = subset_from_selector(S, Array),
    Objects = case Found of
                  [] when P -> 
                      [add_member(K, V, empty(RType))];
                  [] -> 
                    throw({no_path, S});
                  _ ->
                      Found
              end,
    Replaced = set_(Ks, Objects, Val, [], P, RType),
    replace_object(Array, Found, Replaced);



% Path component is index, make Val the index-ed element of the Array.
set_([S|Path], [_|_]=Array, Val, _Acc, P, RType) when ?IS_SELECTOR(S) ->
    N = index_to_n(Array, S),
    case Path of
        [] ->
            lists:sublist(Array, 1, min(1, N-1)) ++
                [Val] ++  
                lists:sublist(Array, N + 1, length(Array));
        _More when P ; N =<length(Array) ->
            lists:sublist(Array, 1, min(1, N-1)) ++
                [set_(Path, lists:nth(N, Array), Val, [], P, RType)] ++
                lists:sublist(Array, N + 1, length(Array));
        _More ->
            throw({no_path, S})
    end;

set_([S|_], NotArray, _Val, _Acc, _P, _RType) when ?IS_SELECTOR(S) -> 
    throw({selector_used_on_non_array, S, NotArray});


% Final Path component is a Name, target is an ARRAY, replace/add Member to all
% selected Objects pulled from the Array.
set_([Name], [_|_]=Array, Val, _Acc, _P, RType) ->
    case found_elements(Name, Array) of
        undefined ->
           merge_members(Array, add_member(Name, Val, empty(RType)));
        Found -> 
            case ?IS_OBJ(Val) of 
                true ->
                    merge_members(remove(Array, Found), Val);
                false -> 
                    replace_member(Name, Array, Val)
            end
    end;

% Path component is a Name, target is an ARRAY,  Set will recursively process
% the selected objects containing a Member with name Name, with the ballance
% ballance of the Path. 
set_([Name|Keys], [_|_]=Array, Val, _Acc, P, RType) ->
    Found = found_elements(Name, Array),
    Objects = case Found of
                  undefined when P ->
                      add_member(Name, 
                                 set_(Keys, empty(RType), Val, [], P, RType), 
                                 empty(RType));
                  undefined ->
                      throw({no_path, Name});
                  _ -> 
                      set_(Keys, Found, Val, [], P, RType)
              end,
    case Found of
        undefined ->
            merge_members(Array, Objects);
        _ ->
            merge_members(Array, [{Name, Objects}])
    end.




%% ----------------------------------------------------------------------------
%% INTERNAL FUNCTIONS
%% ----------------------------------------------------------------------------


% Replace {Name, V} with {Name, Value} for every Object in the List, add if not
% there.
-spec replace_member(name(), [name()|obj()], value()) -> [name()|obj()].
                                              
replace_member(Name, Array, Val) ->
    F = fun(Obj, Acc) when ?IS_OBJ(Obj) ->                
                case get_member(Name, Obj) of
                    undefined -> 
                        [Obj|Acc];
                    _Value ->
                        [add_member(Name, Val, Obj) | Acc]
                end;
           (Element, Acc) ->
                [Element|Acc]
        end,
    lists:reverse(lists:foldl(F, [], Array)).


% Replace Old with New in Array.
-spec replace_object([obj()|value()], [obj(),...], [obj(),...] | obj()) -> 
                                                                [obj()|value()].

replace_object(Same, Same, New) -> New;

replace_object(Array, [], New) ->  lists:append(Array,New);

replace_object(Array, [Old], [New]) ->
     F = fun(Obj) when Obj == Old -> New;
             (Other) -> Other
          end,
      lists:map(F, Array);

replace_object(Array, [Old], New) ->
     F = fun(Obj) when Obj == Old -> New;
             (Other) -> Other
          end,
      lists:map(F, Array).


% Return Values from {Name, Values} from any Objects in the Array or undefined 
% if none.
-spec found_elements(name(), [obj()|value()]) -> jwalk_return() | undefined.
found_elements(Name, Array) ->
    case values_from_member(Name, Array) of
        undefined -> 
            undefined;
        EList -> 
            case lists:filter(fun(R) -> R /= undefined end, EList) of
                [] -> undefined;
                Elements ->
                    Elements
            end
    end.
             

% Return list of Results from trying to get(Name, Obj) from each Obj an Array.
-spec values_from_member(name(), [obj(),...]) -> [obj(),...] | undefined.

values_from_member(Name, Array) ->
    Elements = [walk([Name], Obj) || Obj <- Array, ?IS_OBJ(Obj)],

    case Elements of
        [] -> undefined;
        _ -> dont_nest(Elements)
    end.


% Make sure that we always return an Array - proplists can be over flattened.
dont_nest(H) -> 
    A = lists:flatten(H),
    case A of
        [{_,_}|_] = Obj ->
            [Obj];
        _ ->
            A
    end.


% Select out subset of Object/s that contain Member {K:V}
-spec subset_from_selector(select(), [obj()|value()]) -> [obj()].

subset_from_selector({select, {K,V}}, Array) -> 
    F = fun(Obj) when ?IS_OBJ(Obj) -> 
                get_member(K, Obj) == V;
           (_) -> false
        end,
    lists:filter(F, Array).


% Select out nth Object from Array.
-spec nth(p_index(), [obj()|value()]) -> obj().

nth(first, L) ->
    hd(L);
nth(last, L) ->
    lists:last(L);
nth(N, L)  when N =< length(L) ->
    lists:nth(N, L);
nth(N, L)  when N > length(L) ->
    throw({index_out_of_bounds, N, L}).


-spec remove([obj()], [obj()]) -> [obj()].
remove(Objects, []) -> Objects;
remove(Objects, Remove) -> 
    lists:reverse(ordsets:to_list(
                    ordsets:subtract(ordsets:from_list(Objects),
                                     ordsets:from_list(Remove)))).


%% Representation-specifc object manipulation: adding, deleteing members, etc.

eep_or_pl(proplist, Item) ->  Item;
eep_or_pl(eep, Item)      -> {Item}.


empty(proplist) -> [{}];
empty(eep)      -> {[]};
empty(map)      -> #{}.


normalize_members([{N,V}|Ms]) ->
    {N, V, Ms};
normalize_members({[{N,V}|Ms]}) ->
    {N, V, Ms}.


-spec get_member(name(), obj()) -> term() | 'undefined'.
get_member(Name, #{}=Obj) ->
    map_get(Name, Obj, undefined);

get_member(Name, {PrpLst}) ->
    proplists:get_value(Name, PrpLst, undefined);

get_member(Name, Obj) ->
    proplists:get_value(Name, Obj, undefined).


-spec delete_member(name(), obj()) -> obj().
delete_member(Name, #{}=Obj) ->
    maps:remove(Name, Obj);

delete_member(Name, {PrpLst}) ->
    proplists:delete(Name, PrpLst);

delete_member(Name, Obj) ->
    proplists:delete(Name, Obj).


-spec add_member(name(), value(), obj()) -> obj().
add_member(Name, Val, #{}=Obj) ->
    maps:put(Name, Val, Obj);

add_member(Name, Val, [{}]) ->
    [{Name, Val}];

add_member(Name, Val, {[]}) ->
    {[{Name, Val}]};

add_member(Name, Val, [{_,_}|_]=Obj) ->
    lists:keystore(Name, 1, Obj, {Name, Val});

add_member(Name, Val, {[{_,_}|_]=PrpLst}) ->
    {lists:keystore(Name, 1, PrpLst, {Name, Val})}.


-spec merge_members(obj(), [tuple()]|{[tuple()]}) -> obj().
merge_members([#{}|_] = Maps, Target) ->
    [maps:merge(M, Target) || M <- Maps];
merge_members(Objects, M) ->
    [merge_pl(O, M) || O <- Objects].


merge_pl(P1, [{K,V}|Ts]) when ?IS_PL(P1) ->
    merge_pl(lists:keystore(K, 1, P1, {K,V}), Ts);

merge_pl({P1}, [{K,V}|Ts]) ->
    merge_pl({lists:keystore(K, 1, P1, {K,V})}, Ts);

merge_pl({P1}, {[{K,V}|Ts]}) ->
    merge_pl({lists:keystore(K, 1, P1, {K,V})}, {Ts});

merge_pl(P1, {[]}) ->
    P1;
merge_pl(P1, []) ->
    P1.




index_to_n(_Array, first) -> 1;
index_to_n(Array, last) -> length(Array);
index_to_n(_Array, Integer) -> Integer.


to_binary_list(Keys) ->
    L = case is_tuple(Keys) of
            true -> tuple_to_list(Keys);
            false -> Keys
        end,
    lists:map(fun(K) -> make_binary(K) end, L).



make_binary(K) when is_binary(K); is_number(K) -> K;
make_binary(K) when is_list(K) -> list_to_binary(K);
make_binary(K) when is_atom(K) -> K;
make_binary({select, {K, V}}) -> 
    {select, {make_binary(K), make_binary(V)}}.


% looks for the first object and returns its representation type.
rep_type(#{}) -> map;
rep_type([{}]) -> proplist;
rep_type({[]}) -> eep;
rep_type([#{}|_]) -> map;
rep_type([{_,_}|_]) -> proplist;
rep_type({[{_,_}|_]}) -> eep;
rep_type({[H|_]})  -> rep_type(H);
rep_type([H|_TL]) when is_list(H) -> rep_type(H);
rep_type(_) -> error.



% In support erlang 17 need to roll my own get/3
-spec map_get(name(), #{}, term()) -> term().

map_get(Key, Map, Default) ->
     try  maps:get(Key, Map) of
          Value ->
             Value
     catch
         _:_ ->
             Default
     end.
