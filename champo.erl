-module(champo).
-author('olivier@biniou.info').

%%
%% TODO
%% WTF sur un core 2 utilise que 50% du CPU ?!
%%
%% une roulette pour générer la next gen
%%
%% save/load d'une population (liste de chroms dans un binary term)
%%
-compile([export_all]). %% debug

-export([judge/1, chrom/2]).

%% Idonea's enigma parameters
-define(ALPHABET_SIZE, 14). %% real case
-define(MAXWORDLENGTH, 8).  %% real case

%% GA parameters
-define(H_ALPHABET_SIZE, (?ALPHABET_SIZE bsr 1)).
-define(POP_SIZE, 10000). %% 200). %%200000).
-define(H_POP_SIZE, (?POP_SIZE bsr 1)).

%% Mutations
-define(NB_MUTATIONS, 5).
-define(P_MUTATION, 200). %% 1 chance sur 1000

%% CPU cooling pauses
-define(TOS, 30). %% seconds
-define(TOM, ?TOS*1000).

%% Registered processes
-define(JUDGE, judge).

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
		 [10, 3, 4],
		 [8, 5, 2, 6, 13, 5],
		 [3, 7, 14, 5, 4, 8, 1, 13]
		]).

-define(WORST(X), (X*25+1)).
-define(WORST_GUESS_EVER, (
	  ?WORST(4) *
	  ?WORST(2) *
	  ?WORST(7) *
	  ?WORST(6) *
	  ?WORST(2) *
	  ?WORST(5) *
	  ?WORST(2) *
	  ?WORST(3) *
	  ?WORST(6) *
	  ?WORST(8)
	 )).
%% -define(EXACT_GUESS, 1). %% une évidence, non ?

-define(H1, "         1").
-define(H2, "12345678901234").
-define(HL, "--------------").

-define(PUTSTR(X), io:format("~s~n", [X])).

worst() ->
    io:format("Worst guess ever: ~p~n", [?WORST_GUESS_EVER]).

%% tidier
new_chrom(C) ->
    spawn(fun () -> (?MODULE):chrom(C, undefined) end).

start() ->
    %% Start crypto application
    io:format("[+] Starting crypto application: ~p~n", [crypto:start()]),

    %% Load dictionary
    io:format("[+] Loading dictionary: ", []),
    Dict = dict_load(),
    io:format("~p words~n", [length(Dict)]),

    %% Start judge process
    %% oliv3
    %% Judge = spawn(?MODULE, judge, [Dict]),
    %% tidier
    Judge = spawn(fun () -> (?MODULE):judge(Dict) end),
    register(?JUDGE, Judge),
    io:format("[+] Judge pid: ~p~n", [Judge]),

    %% Create initial population
    Pop = population(),
    Pids = [new_chrom(C) || C <- Pop],
    io:format("[+] ~p chromosomes created~n", [length(Pids)]),

    %% Start GA
    loop(Pids, 1).

receive_result(Ref) ->
    receive
	{Ref, Result} ->
	    Result
    end.


match(1) ->
    "<- Solution";
match(_) ->
    "".

flatten(List) ->
    flatten(List, "").
flatten([Last], Acc) ->
    Acc ++ Last;
flatten([Word|Words], Acc) ->
    flatten(Words, Acc ++ Word ++ " ").

display({_Pid, C, Score}) ->
    %% io:format("[C] ~p Alphabet: ~p Score: ~p Sentence: ~p ~s~n", [Pid, pp(C), Score, flatten(sentence(C)), match(Score)]).
    io:format("[C] Alphabet: ~p => ~p ~s(~p) (~p)~n", [pp(C), flatten(sentence(C)), match(Score), Score, ?WORST_GUESS_EVER-Score]).

loop(Pids, Gen) ->
    %% Ask all chroms to evaluate
    Ref = make_ref(),
    Self = self(),
    [Pid ! {Self, Ref, evaluate} || Pid <- Pids],

    %% Receive evaluations
    Evaluations = [receive_result(Ref) || _Pid <- Pids],

    %% WIP version avec la roulette russe
    NegEvals = [neg_score(E) || E <- Evaluations],
    %% io:format("NegEvals= ~p~n", [NegEvals]),
    Results = lists:reverse(lists:keysort(3, NegEvals)),

    %% WIP temp roll-back version sans roulette russe
    %% Results = lists:keysort(3, Evaluations),
    %% io:format("Results= ~p~n", [Results]),

    %% Top 10
    Top10 = top10(Results),
    io:format("[*] Generation: ~p, ~p individuals evaluated~n", [Gen, Gen*?POP_SIZE]),
    io:format("[i] ~p processes~n", [length(processes())]),
    io:format("[*] Top 10:~n", []),
    [display(T) || T <- Top10],
    io:format("~n", []),

    %% Divide poulation in two
    {Winners, Losers} = lists:split(?H_POP_SIZE, Results),
    %% io:format("Pop= ~p~nW= ~p~nL= ~p~n", [Results, Winners, Losers]),

    %% Kill losers
    [LoserPid ! die || {LoserPid, _Alphabet, _Score} <- Losers],

    %% Compute score of all the winners
    SumScores = sum_scores(Winners),
    %% io:format("[i] Population score: ~p~n", [SumScores]),

    %% Create new population
    NewPids = new_population2(?H_POP_SIZE, Winners, SumScores, [Pid || {Pid, _A, _S} <- Winners]),

    %% Sleep for a while to cool the CPU
    timer:sleep(5000), %% io races, let 5 seconds for mutations to occur
    io:format("[.] Sleeping ~p seconds... ", [?TOS]),
    timer:sleep(?TOM-5000),
    io:format("done.~n~n", []),

    %% Start again
    ?MODULE:loop(NewPids, Gen+1).

top10(List) ->
    {L1, _} = lists:split(10, List),
    L1.

neg_score({Pid, Alphabet, Score}) ->
    {Pid, Alphabet, ?WORST_GUESS_EVER-Score}.

%% version avec roulette
new_population3(_, Parents, _) ->
    L = [Pid || {Pid, _, _} <- Parents],
    lists:flatten(lists:duplicate(2, L)).

new_population2(0, _Parents, _MaxScore, Acc) ->
    Acc;
new_population2(N, Parents, MaxScore, Acc) ->
    {Parent1Pid, Chrom1, _S} = roulette(Parents, MaxScore, undefined),
    {_Parent2Pid, Chrom2, _S2} = roulette(Parents, MaxScore, Parent1Pid),
    {_, _, MS} = now(),
    %% io:format("np2(~p), ~p~n", [N, [E || E <- Acc]]),
    {Child1, Child2} = case MS rem 2 of
			   0 ->
			       xover1({Chrom1, Chrom2});
			   1 ->
			       xover2({Chrom1, Chrom2})
		       end,
    Pid1 = new_chrom(Child1),
    Pid2 = new_chrom(Child2),
    maybe_mutate(Pid1),
    maybe_mutate(Pid2),
    new_population2(N-2, Parents, MaxScore, [Pid1, Pid2 | Acc]).

roulette(Parents, MaxScore, NotThisPid) ->
    Score = crypto:rand_uniform(0, MaxScore),
    {Pid, _A, _S} = This = extract(Parents, Score),
    if
	Pid == NotThisPid ->
	    roulette(Parents, MaxScore, NotThisPid);
	true ->
	    This
    end.

f({_Pid, Alphabet, _Score}) ->
    pp(Alphabet).

extract(Parents, Score) ->
    extract(Parents, Score, 0).
extract([], Score, CurScore) ->
    io:format("[!] WTF no more parents Score= ~p CurScore= ~p~n", [Score, CurScore]),
    exit(duergl);
extract([{_Pid, _A, S} = Element | Parents], Score, CurScore) ->
    NewScore = CurScore + S,
    if
	NewScore >= Score ->
	    %% io:format("[d] Found element ~p, score ~p -> ~p >= ~p~n~n", [f(Element), S, NewScore, Score]),
	    Element;
	true ->
	    %% io:format("[d] Skipp element ~p, score ~p -> ~p  < ~p~n",   [f(Element), S, NewScore, Score]),
	    extract(Parents, Score, NewScore)
    end.

new_population(Winners) ->
    %% io:format("WINNERS mating !~n~p~n", [Winners]),
    %% The new population consists of the winners plus
    %% the children created by mating the winners (possibly mutating)
    WinnersPids = [Pid || {Pid, _Alphabet, _Score} <- Winners],
    %% [maybe_mutate(Pid) || Pid <- WinnersPids],
    %% io:format("WinnersPids: ~p~n", [WinnersPids]),
    new_population(Winners, WinnersPids).
new_population([], Acc) ->
    Acc;
new_population([{_ParentPid1, Parent1, _Score1}, {_ParentPid2, Parent2, _Score2} | Rest] = _Chose, Acc) ->
    %% io:format("new_population ~p~n", [_Chose]),

    %% XXX c'est bien la peine de coder xover2 si c'est
    %% pour ne pas l'utiliser
    {Child1, Child2} = xover1({Parent1, Parent2}),
    Pid1 = new_chrom(Child1),
    Pid2 = new_chrom(Child2),
    maybe_mutate(Pid1),
    maybe_mutate(Pid2),
    new_population(Rest, [Pid1, Pid2 | Acc]).

sum_scores(Pop) ->
    lists:sum([Score || {_Pid, _Alphabet, Score} <- Pop]).

maybe_mutate(Pid) ->
    case crypto:rand_uniform(0, ?P_MUTATION) of
	0 ->
	    mutate(Pid);
	_Other ->
	    ok
    end.

mutate(Pid) ->
    Mutation = crypto:rand_uniform(0, ?NB_MUTATIONS),
    Pid ! {mutate, Mutation}.

chrom(C, Score) ->
    receive
	{Pid, Ref, evaluate} when Score == undefined ->
	    S = evaluate(C),
	    %% error_logger:info_msg("~p evaluated to: ~p~n", [C, S]),
	    Pid ! {Ref, {self(), C, S}},
	    chrom(C, S);

	{Pid, Ref, evaluate} ->
	    Pid ! {Ref, {self(), C, Score}},
	    chrom(C, Score);

	{mutate, 0} ->
	    NewC = mut_reverse(C),
	    chrom(NewC, undefined);

	{mutate, 1} ->
	    NewC = mut_split_swap(C),
	    chrom(NewC, undefined);

	{mutate, 2} ->
	    NewC = mut_randomize_full(),
	    chrom(NewC, undefined);

	{mutate, 3} ->
	    NewC = mut_randomize_one(C),
	    chrom(NewC, undefined);

	{mutate, 4} ->
	    NewC = mut_swap_two_genes(C),
	    chrom(NewC, undefined);

	die ->
	    %% io:format("[i] ~p exiting~n", [self()]),
	    ok;
	
	_Other ->
	    io:format("[?] Oups got other message: ~p~n", [_Other])
    end.

translate(Word, C) ->
    [element(Letter, C) || Letter <- Word].

sentence(C) ->
    [translate(Word, C) || Word <- ?RIDDLE].

evaluate(C) ->
    Sentence = sentence(C),
    %% error_logger:info_msg("Alphabet: ~p, Sentence: ~p~n", [pp(C), Sentence]),
    ?JUDGE ! {self(), {check, Sentence}},
    receive
	Score ->
	    Score
    end.

judge(Dict) ->
    receive
	{Pid, {check, Sentence}} ->
	    Score = check_sentence(Sentence, Dict),
	    Pid ! Score,
	    judge(Dict)
    end.

%% chargement et parsing du dictionnaire
%% FMI avec le dico.txt actuel
%% > length(champo:dict_load()).  
%% 13215 %% words

dict_load() ->
    dict_load("dico.txt").
dict_load(File) ->
    {ok, B} = file:read_file(File),
    L = binary_to_list(B),
    L2 = string:tokens(L, [10, 13]),
    menache(L2).

%%
%% ménache dans le dictionnaire, on ne garde
%% que les mots de taille <= ?MAXWORDLEN

%% oliv3:
%% menache(Words) ->
%%     lists:filter(fun(Str) -> length(Str) =< ?MAXWORDLENGTH end, Words).
%% tidier:
menache(Words) ->
    [Str || Str <- Words, length(Str) =< (?MAXWORDLENGTH)].


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
%%
%% > Dict.
%% ["abc","hello","world"]
%% > champo:find_in_dict("zprle", Dict).
%% {"world",5}
%% > champo:find_in_dict("prouta", Dict).
%% undefined
%%
%% FIXME could be better, partir avec BEAUCOUP = -1 et tester dessus
%% ou < si != -1
-define(BEAUCOUP, (($z-$a+1) * ?ALPHABET_SIZE)).

find_in_dict(String, Dict) ->
    find_in_dict(String, Dict, undefined, ?BEAUCOUP).

find_in_dict(_String, [], undefined, _BestSoFar) ->
    ?BEAUCOUP;
find_in_dict(_String, [], BestWord, BestSoFar) ->
    {BestWord, BestSoFar};
find_in_dict(String, [Word|Words], BestWord, BestSoFar) ->
    Score = diff(String, Word),
    case Score of
	0 ->
	    {Word, 0};
	S when S < BestSoFar ->
	    find_in_dict(String, Words, Word, S);
	_Other ->
	    find_in_dict(String, Words, BestWord, BestSoFar)
    end.


%% match a list of words vs a dict
%%
%% > Dict.
%% ["abc","hello","world"]
%% > Words = ["helli", "world", "absz"].
%% ["helli","world","absz"]
%% > champo:match(Words, Dict).         
%% [{"hello",6},{"world",0},undefined]
match(Words, Dict) ->
    [find_in_dict(Word, Dict) || Word <- Words].

check_sentence(Sentence, Dict) ->
    %% NOTE S+1 pour multiplier des ints > 0,
    %% le score ideal est donc: 1
    Scores = [S+1 || {_Word, S} <- match(Sentence, Dict)],
    multiply(Scores).

%% XXX faire un lists:qqc avec un accum
multiply(Scores) ->
    multiply(Scores, 1).
multiply([], Acc) ->
    Acc;
multiply([Score|Scores], Acc) ->
    multiply(Scores, Score*Acc).

%%
%% generate a random chromosome
%%
to_char(X) ->
    $a + (X rem 26).

create() ->
    Rnd = crypto:rand_bytes(?ALPHABET_SIZE),
    AsList = binary_to_list(Rnd),
    AsChars = [to_char(C) || C <- AsList],
    list_to_tuple(AsChars).

population() ->
    [create() || _ <- lists:seq(1, ?POP_SIZE)].

t2b(X) ->
    list_to_binary(tuple_to_list(X)).

b2t(X) ->
    list_to_tuple(binary_to_list(X)).

%% pretty print a chromosome
pp(X) ->
    tuple_to_list(X).


%%
%% mix 2 chromosomes
%%

%% one-point cross-over
xover1({C1, C2}) ->
    Bin1 = t2b(C1),
    Bin2 = t2b(C2),
    Rnd = crypto:rand_uniform(1, ?ALPHABET_SIZE),
    %% io:format("xover1: pos= ~p~n", [Rnd]),
    %% h1(Rnd), h2(Rnd),
    %% io:format("~s~n", [split(pp(C1), Rnd, $|)]),
    %% io:format("~s~n", [split(pp(C2), Rnd, $|)]),
    {L1, R1} = erlang:split_binary(Bin1, Rnd),
    {L2, R2} = erlang:split_binary(Bin2, Rnd),
    NC1 = erlang:list_to_binary([L1, R2]),
    NC2 = erlang:list_to_binary([L2, R1]),
    Child1 = b2t(NC1),
    Child2 = b2t(NC2),
    {Child1, Child2}.

%% two-point cross-over
xover2({C1, C2}) ->
    LC1 = tuple_to_list(C1),
    LC2 = tuple_to_list(C2),

    First  = crypto:rand_uniform(2, ?ALPHABET_SIZE-2),
    Second = crypto:rand_uniform(First+1, ?ALPHABET_SIZE-1),

    %% erf le lame check
    case Second > First of
	true -> ok;
	false -> exit(mais_heu)
    end,

    %% io:format("xover2: ~p / ~p~n", [First, Second]),

    {Left1, Rest1} = lists:split(First, LC1),
    {Left2, Rest2} = lists:split(First, LC2),

    Delta = Second - First,

    {Middle1, Right1} = lists:split(Delta, Rest1),
    {Middle2, Right2} = lists:split(Delta, Rest2),

    Child1 = list_to_tuple(Left1 ++ Middle2 ++ Right1),
    Child2 = list_to_tuple(Left2 ++ Middle1 ++ Right2),

    {Child1, Child2}.


test() ->
    {P1, P2} = {create(), create()},
    io:format("Parent1: ~p~n", [pp(P1)]),
    io:format("Parent2: ~p~n", [pp(P2)]),
    {C1, C2} = xover1({P1, P2}),
    io:format("Child1:  ~p~n", [pp(C1)]),
    io:format("Child2:  ~p~n", [pp(C2)]).


test2() ->
    {P1, P2} = {create(), create()},
    io:format("Parent1: ~p~n", [pp(P1)]),
    io:format("Parent2: ~p~n", [pp(P2)]),
    {C1, C2} = xover2({P1, P2}),
    io:format("Child1:  ~p~n", [pp(C1)]),
    io:format("Child2:  ~p~n", [pp(C2)]).

%%
%% Mutations
%%

%% 1. Reverse chromosome
mut_reverse(C) ->
    New = list_to_tuple(lists:reverse(tuple_to_list(C))),
    io:format("[m] Reverse chromosome: ~p -> ~p~n", [pp(C), pp(New)]),
    New.

%% 2. Split in two then swap
mut_split_swap(C) ->
    {Left, Right} = lists:split(?H_ALPHABET_SIZE, tuple_to_list(C)),
    New = list_to_tuple(Right ++ Left),
    io:format("[m] Split/Swap chromosome: ~p -> ~p~n", [pp(C), pp(New)]),
    New.

%% 3. Randomize full
mut_randomize_full() ->
    C = create(),
    io:format("[m] Randomize chromosome full: ~p~n", [pp(C)]),
    C.

%% 4. Radomize only one char
mut_randomize_one(C) ->
    Position = crypto:rand_uniform(0, ?ALPHABET_SIZE) + 1,
    <<NewChar>> = crypto:rand_bytes(1),
    Char = to_char(NewChar),
    New = setelement(Position, C, Char),
    io:format("[m] Randomize chromosome one at pos ~p: ~p -> ~p~n",
	      [Position, pp(C), pp(New)]),
    New.

%% 5. Swap two characters
mut_swap_two_genes(C) ->
    {Position1, Position2} = random2(),
    Char1 = element(Position1, C),
    Char2 = element(Position2, C),
    Tmp = setelement(Position1, C, Char2),
    New = setelement(Position2, Tmp, Char1),
    io:format("[m] Swap two genes at pos ~p/~p: ~p -> ~p~n",
	      [Position1, Position2, pp(C), pp(New)]),
    New.

test_mut_swap_two_genes() ->
    C = create(),
    N = mut_swap_two_genes(C),
    ?PUTSTR(?H1),
    ?PUTSTR(?H2),
    ?PUTSTR(pp(C)),
    ?PUTSTR(?HL),
    ?PUTSTR(pp(N)),
    ok.


split(String, Pos, Delim) ->
    {L, R} = lists:split(Pos, String),
    S = io_lib:format("~s~c~s", [L, Delim, R]),
    %% lists:flatten(S).
    S.



h1(Pos) ->
    io:format("~s~n", [split(?H1, Pos, $ )]).
h2(Pos) ->
    io:format("~s~n", [split(?H2, Pos, $|)]).
hl(Pos) ->
    io:format("~s~n", [split(?HL, Pos, $-)]).


%%
%% 2 random integers in [1..?ALPHABET_SIZE]
%%
random2() ->
    Rnd1 = crypto:rand_uniform(0, ?ALPHABET_SIZE) + 1,
    random2(Rnd1).
random2(Rnd1) ->
    Rnd2 = crypto:rand_uniform(0, ?ALPHABET_SIZE) + 1,
    if
	Rnd1 == Rnd2 ->
	    random2(Rnd1);
	true ->
	    {Rnd1, Rnd2}
    end.
