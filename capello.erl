-module(capello).
-author('olivier@biniou.info').

%% XXX virer l'appel a ets:tab2list et faire un traversal de la table
%% (quoique l'appel a tab2list a l'air de rien bouffer, mais bon. sexy or not)

%% ETS/ make_tuple(ets:new(), 8).
%% list_to_tuple([undefined | [ets:new(list_to_atom(integer_to_list(I)), [set, named_table]) || I <- lists:seq(2, 8)]]).
%% et en named table. du coup prefixage avec l'atom

%% TODO version intermediaire avec le dict, coder la longueur
%% avant ie {'7', [6, 7, 3, 8, 5, 9, 5]}

%%
%% Maitre Capello
%%
%% Le module qui charge le dictionnaire et se charge
%% de verifier que des mots sont dedans
%%
-include("champo.hrl").

-compile([export_all]).

-export([start/0, loop/1, stop/0]).
-export([check/1, sentence/1]).
-export([three/1]).


-define(SERVER, ?MODULE).
-record(state, {words, three}).

%% The riddle
%% http://www.youtube.com/watch?v=5ehHOwmQRxU
-define(RIDDLE, [
		 [1, 2, 3, 4],
		 [2, 5],
		 [6, 7, 3, 8, 5, 9, 5],
		 [10, 5, 11, 2, 5, 8],
		 [2, 5],
		 [9, 1, 7, 12, 5],
		 [5, 4],
		 ?WORD3,
		 [8, 5, 2, 6, 13, 5],
		 [3, 7, 14, 5, 4, 8, 1, 13]
		]).
%% Therefore we set
-define(MAX_WORD_LENGTH, 8).


start() ->
    io:format("[+] Loading dictionary: ", []),
    {Words, Three} = dict_load(),
    io:format("~p words (~p of 3 letters)~n", [ets:info(Words, size), ets:info(Three, size)]),
    %% io:format("~p words~n", [ets:info(Words, size)]),
    Pid = spawn(?SERVER, loop, [#state{words=Words, three=Three}]),
    register(?SERVER, Pid),
    io:format("[i] ~p module started, pid ~p~n", [?SERVER, Pid]).


stop() ->
    Ref = make_ref(),
    ?SERVER ! {self(), Ref, stop},
    receive
	{Ref, stopped} ->
	    ok
    end.


three(Chrom) ->
    Ref = make_ref(),
    ?SERVER ! {self(), {Ref, three, Chrom}},
    receive
	{Ref, Result} ->
	    Result
    end.


check(Chrom) ->
    ?SERVER ! {self(), {check, Chrom}},
    receive
	Result ->
	    Result
    end.

%% ------------------------------------------------------------------

loop(#state{words=Words, three=Three} = State) ->
    receive
	%% Any ->
	%%     io:format("Got message: ~p~n", [Any]);

	{Pid, {Ref, three, Chrom}} ->
	    TWord = translate(?WORD3, Chrom),
	    %% HERE test sur lookup =/= []
	    In = ets:lookup(Three, TWord) =/= [],
	    Pid ! {Ref, In};

	{Pid, {check, Chrom}} ->
	    Sentence = sentence(Chrom),
	    %% io:format("Checking sentence: ~p~n", [Sentence]),
	    Score = check_sentence(Sentence, Words),
	    Pid ! Score;

	{Pid, Ref, stop} ->
	    Pid ! {Ref, stopped};

	Msg ->
	    io:format("~p got message: ~p~n", [?SERVER, Msg])
    end,
    ?MODULE:loop(State).

%% ------------------------------------------------------------------

%% chargement et parsing du dictionnaire
dict_load() ->
    dict_load("dico.txt").
dict_load(File) ->
    {ok, B} = file:read_file(File),
    L = binary_to_list(B),
    L2 = string:tokens(L, [10, 13, $-, $', $ ]),
    L3 = menache(L2),
    build_ets(L3).

build_ets(Words) ->
    Tid = ets:new(words, [set]),
    Three = ets:new(three, [set]),
    insert(Words, Tid, Three),
    {Tid, Three}.

insert([], _Tid, _Three) ->
    ok;
insert([Word|Words], Tid, Three) when length(Word) == 3->
    true = ets:insert(Tid, {Word}),
    true = ets:insert(Three, {Word}),
    insert(Words, Tid, Three);
insert([Word|Words], Tid, Three) ->
    true = ets:insert(Tid, {Word}),
    insert(Words, Tid, Three).

%% menache dans le dictionnaire, on ne garde
%% que les mots de taille >= 2 et <= ?MAX_WORD_LENGTH
menache(Words) ->
    [Str || Str <- Words, length(Str) >= 2 andalso length(Str) =< ?MAX_WORD_LENGTH].

%% translate a word to french
translate(Word, Chrom) ->
    [element(Letter, Chrom) || Letter <- Word].

%% translate the whole riddle
sentence(Chrom) ->
    [translate(Word, Chrom) || Word <- ?RIDDLE].

-define(BEAUCOUP, (($z-$a+1) * ?ALPHABET_SIZE)).

%% diff entre 2 strings
%% ~= algo de Hamming
diff(Str1, Str2) when length(Str1) =:= length(Str2) ->
    diff(Str1, Str2, 0);
diff(_Truc1, _Truc2) ->
    undefined.

diff(Str, Str, Score) ->
    Score;
diff([], [], Score) ->
    Score;
diff([H1|T1], [H2|T2], Score) ->
    diff(T1, T2, Score + abs(H1-H2)).

%% Truc qui fait des calculs de distance d'un mot vs un dict
find_best_match(String, Words) ->
    find_best_match(String, Words, undefined, ?BEAUCOUP).

find_best_match(_String, [], undefined, _BestSoFar) ->
    ?BEAUCOUP;
find_best_match(_String, [], BestWord, BestSoFar) ->
    {BestWord, BestSoFar};
find_best_match(String, [Word|Words], BestWord, BestSoFar) ->
    Score = diff(String, Word),
    %% io:format("Score: ~p~n", [Score]),
    case Score of
	%% undefined ->
	%%     find_best_match(String, Words, BestWord, BestSoFar);
	0 ->
	    {Word, 0};
	S when S < BestSoFar ->
	    find_best_match(String, Words, Word, S);
	_Other -> %% score superieur
	    find_best_match(String, Words, BestWord, BestSoFar)
    end.

%% match a list of words vs a dictionary stored in an ETS table
%% TODO mettre l'enigme au format {Len, [Letters]}
%% pour eviter l'appel a length a chaque fois
%% (et dans la version ETS, taper dans la bonne table)
match(Words, List) ->
    [find_best_match(Word, List) || Word <- Words].


%% Translate the riddle then returns the score
check_sentence(Sentence, ETS) ->
    %% NOTE S+1 pour multiplier des ints > 0,
    %% le score ideal est donc: 1
    List = [W || {W} <- ets:tab2list(ETS)],
    %% io:format("Words: ~p~n", [List]),
    Scores = [S+1 || {_Word, S} <- match(Sentence, List)],
    multiply(Scores).

multiply(Scores) ->
    lists:foldr(fun(Elem, Acc) -> Elem * Acc end, 1, Scores).
