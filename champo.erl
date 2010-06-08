-module(champo).
-author('olivier@biniou.info').

-include("champo.hrl").

%% Nombre de solutions à ce pb: 26^14
%%
%% > math:pow(26,14).
%% 6.450997470329715e19
%%
%% ce qui fait... beaucoup :)

%%
%% TODO
%% WTF sur un core 2 utilise que 50% du CPU ?!
%%
%% save/load d'une population (liste de chroms dans un binary term)
%%
%% modules "chrom" "config"
%%
%% Lors du display des stats/time, rajouter le timestamp / human readable
%% eg ala syslog
%%

-compile([export_all]). %% debug

-export([chrom/2]).

%% GA parameters
-define(POP_SIZE, 20000). %% 200). %%200000).

%% Mutations
-define(P_MUTATION, 100). %%1000). %% 1 chance sur 1000
-define(NB_MUTATIONS, 6).

%% CPU cooling pauses
-define(TOS, 5). %% 30). %% seconds
-define(TOM, ?TOS*1000).

-define(H_POP_SIZE, (?POP_SIZE bsr 1)).

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

-define(TOP, 15). %% Top N display

-define(PUTSTR(X), io:format("~s~n", [X])).

-define(HINT, "noma"). %% "amon" reversed

worst() ->
    io:format("Worst guess ever: ~p~n", [?WORST_GUESS_EVER]).

%% tidier
new_chrom(C) ->
    spawn(fun () -> (?MODULE):chrom(C, undefined) end).

start() ->
    %% Start crypto application
    io:format("[+] Starting crypto application: ~p~n", [crypto:start()]),

    %% Start dictionnary module
    capello:start(),

    %% Create initial population
    Pop = population(),
    Pids = [new_chrom(C) || C <- Pop],
    io:format("[+] ~p chromosomes created~n", [length(Pids)]),

    io:format("[i] main loop pid: ~p~n", [self()]),

    %% Start GA
    loop(Pids, 1, 0).

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
    io:format("[C] Alphabet: ~p => ~p ~s(~p) (~p)~n", [pp(C), flatten(capello:sentence(C)), match(Score), Score, ?WORST_GUESS_EVER-Score]).

ts() ->
    {_Date, {Hour, Min, Sec}} = calendar:local_time(),
    io_lib:format("~2B:~2.10.0B:~2.10.0B", [Hour, Min, Sec]).

loop(Pids, Gen, RunTime) ->
    Start = now(),

    %% Ask all chroms to evaluate
    Ref = make_ref(),
    Self = self(),
    [Pid ! {Self, Ref, evaluate} || Pid <- Pids],

    %% Receive evaluations
    Evaluations = [receive_result(Ref) || _Pid <- Pids],


    %% Inverse scores
    %% XXX WHY THE FUCK ? On sort par score croissant est c'est marre
    %% En fait non on a basoin du score reversed pour l'algo de la roulette
    NegEvals = [neg_score(E) || E <- Evaluations],
    %% Sort by best score descending
    Results = lists:reverse(lists:keysort(3, NegEvals)),

    %% Display Top N
    Top = top(Results),
    io:format("~n[*] Generation: ~p, ~p individuals evaluated~n", [Gen, Gen*?POP_SIZE]),
    io:format("[i] ~p processes~n~n", [length(processes())]),
    io:format("[*] Top ~p:~n", [?TOP]),
    [display(T) || T <- Top],
    io:format("~n", []),

    %% Divide poulation in two
    %% TODO ? garder 25% et regénérer 75% ?
    {Winners, Losers} = lists:split(?H_POP_SIZE, Results),

    %% Kill losers
    [LoserPid ! die || {LoserPid, _Alphabet, _Score} <- Losers],

    %% Compute score of all the winners
    SumScores = sum_scores(Winners),

    %% Create new population
    NewPids = new_population2(?H_POP_SIZE, Winners, SumScores, [Pid || {Pid, _A, _S} <- Winners]),

    Now = now(),
    ElapsedR = (timer:now_diff(Now, Start)) / 1000000,
    Elapsed = RunTime + ElapsedR,
    io:format("~n[i] ~s, done in ~ps (~ps mean)~n", [ts(), ElapsedR, (Elapsed/Gen)]),

    %% Sleep for a while to cool the CPU
    timer:sleep(?TOM),

    %% Start again
    ?MODULE:loop(NewPids, Gen+1, Elapsed).

top(List) ->
    {L1, _} = lists:split(?TOP, List),
    L1.


neg_score({Pid, Alphabet, Score}) ->
    {Pid, Alphabet, ?WORST_GUESS_EVER-Score}.

%% version avec roulette
new_population2(0, _Parents, _MaxScore, Acc) ->
    Acc;
new_population2(N, Parents, MaxScore, Acc) ->
    {Parent1Pid, Chrom1, _S} = roulette(Parents, MaxScore, undefined),
    {_Parent2Pid, Chrom2, _S2} = roulette(Parents, MaxScore, Parent1Pid),

    {_, _, MS} = now(),
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
	    S = capello:check(C),
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

	{mutate, 5} ->
	    NewC = mut_shift(C),
	    chrom(NewC, undefined);

	die ->
	    %% io:format("[i] ~p exiting~n", [self()]),
	    ok;

	_Other ->
	    io:format("[?] Oups got other message: ~p~n", [_Other])
    end.


%%
%% generate a random chromosome
%%
to_char(X) ->
    $a + (X rem 26).

create() ->
    Chrom = random(),
    case is_viable(Chrom) of
	true ->
	    Chrom;
	false ->
	    create()
    end.

is_viable(Chrom) ->
    capello:three(Chrom). %% will return true or false

random() ->
    random(?ALPHABET_SIZE-length(?HINT), ?HINT, 26-length(?HINT), lists:seq($a, $z) -- ?HINT).
random(0, Acc, _N, _S) ->
    list_to_tuple(lists:reverse(Acc));
random(Size, Acc, N, Chars) ->
    Pos = crypto:rand_uniform(0, N) + 1,
    Elem = lists:nth(Pos, Chars),
    NewChars = Chars -- [Elem],
    random(Size-1, [Elem|Acc], N-1, NewChars).

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
    {P1, P2} = T1 = {create(), create()},
    io:format("Parent1: ~p~n", [pp(P1)]),
    io:format("Parent2: ~p~n", [pp(P2)]),
    {C1, C2} = xover1(T1),
    io:format("Child1:  ~p~n", [pp(C1)]),
    io:format("Child2:  ~p~n", [pp(C2)]).


test2() ->
    {P1, P2} = T1 = {create(), create()},
    io:format("Parent1: ~p~n", [pp(P1)]),
    io:format("Parent2: ~p~n", [pp(P2)]),
    {C1, C2} = xover2(T1),
    io:format("Child1:  ~p~n", [pp(C1)]),
    io:format("Child2:  ~p~n", [pp(C2)]).

%%
%% Mutations
%%

%% -define(MUT(F,A), io:format(F, A)).
-define(MUT(F,A), io:format(".", [])).

%% 1. Reverse chromosome
mut_reverse(C) ->
    New = list_to_tuple(lists:reverse(tuple_to_list(C))),
    ?MUT("[m] Reverse chromosome: ~p -> ~p~n", [pp(C), pp(New)]),
    New.

%% 2. Split in two then swap
mut_split_swap(C) ->
    {Left, Right} = lists:split(?H_ALPHABET_SIZE, tuple_to_list(C)),
    New = list_to_tuple(Right ++ Left),
    ?MUT("[m] Split/Swap chromosome: ~p -> ~p~n", [pp(C), pp(New)]),
    New.

%% 3. Randomize full
mut_randomize_full() ->
    C = create(),
    ?MUT("[m] Randomize chromosome full: ~p~n", [pp(C)]),
    C.

%% 4. Radomize only one char
mut_randomize_one(C) ->
    Position = crypto:rand_uniform(0, ?ALPHABET_SIZE) + 1,
    <<NewChar>> = crypto:rand_bytes(1),
    Char = to_char(NewChar),
    New = setelement(Position, C, Char),
    ?MUT("[m] Randomize chromosome one at pos ~p: ~p -> ~p~n",
	 [Position, pp(C), pp(New)]),
    New.

%% 5. Swap two characters
mut_swap_two_genes(C) ->
    {Position1, Position2} = random2(),
    Char1 = element(Position1, C),
    Char2 = element(Position2, C),
    Tmp = setelement(Position1, C, Char2),
    New = setelement(Position2, Tmp, Char1),
    ?MUT("[m] Swap two genes at pos ~p/~p: ~p -> ~p~n",
	 [Position1, Position2, pp(C), pp(New)]),
    New.

%% 6. Shift a chromosome
mut_shift(C) ->
    [H|T] = tuple_to_list(C),
    New = list_to_tuple(T++[H]),
    ?MUT("[m] Shift chromosome: ~p -> ~p~n", [pp(C), pp(New)]),
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
