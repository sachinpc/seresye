%%%  ERESYE, an ERlang Expert SYstem Engine
%%%
%%% Copyright (c) 2005-2010, Francesca Gangemi, Corrado Santoro
%%% All rights reserved.
%%%
%%% You may use this file under the terms of the BSD License. See the
%%% license distributed with this project or
%%% http://www.opensource.org/licenses/bsd-license.php
-module(eresye_ontology).

%%====================================================================
%% Include files
%%====================================================================
-include("eres_ontology.hrl").

%%====================================================================
%% External exports
%%====================================================================
-export([compile/1, compile/2]).

%%====================================================================
%% External functions
%%====================================================================

%% @doc Compiles an ontology file
compile(FileName, _Options) ->
    {ok, AbstractErlangForm} = epp:parse_file(FileName ++
                                                  ".onto",
                                              "", []),
    {ok, Classes} = compile_lines([],
                                  list_to_atom(FileName), AbstractErlangForm),
    NewClasses = resolve_inheritance(Classes),
    IsAHierarchy = generate_hierarchy_tree([], Classes,
                                           Classes),
    FatherOfHierarchy = reverse_hierarchy_tree([],
                                               IsAHierarchy, IsAHierarchy),
    IncludeLines = generate_include_file(NewClasses),
    {ok, IncludeFile} = file:open(FileName ++ ".hrl",
                                  [write]),
    io:format(IncludeFile, "~s", [IncludeLines]),
    file:close(IncludeFile),

    IsClassLines = generate_is_class([], IsAHierarchy),
    IsALines = generate_is_a([], IsAHierarchy),
    {CastClasses, CastLines} = generate_cast({[], []},
                                             FatherOfHierarchy, NewClasses),
    ChildOfLines = generate_childof([], FatherOfHierarchy),

    OntologyFileName = FileName,
    {ok, ConversionFile} = file:open(OntologyFileName ++
                                         ".erl",
                                     [write]),
    io:format(ConversionFile, "-module (~s).~n",
              [OntologyFileName]),
    io:format(ConversionFile, "-include (\"~s.hrl\").~n",
              [FileName]),
    io:format(ConversionFile,
              "-export ([is_class/1, is_a/2, ~s childof/1])."
              "~n~n",
              [lists:flatten([io_lib:format("'~s'/1,", [X])
                              || X <- CastClasses])]),
    io:format(ConversionFile, "~s", [IsClassLines]),
    io:format(ConversionFile, "~s", [IsALines]),
    io:format(ConversionFile, "~s", [ChildOfLines]),
    io:format(ConversionFile, "~s", [CastLines]),
    file:close(ConversionFile),
    ok.

%% @doc Compiles an ontology file
compile(FileName) -> compile(FileName, []).

%%====================================================================
%% Internal functions
%%====================================================================
%% @doc compile the lines of the ontology, given its erlang
%%              abstract form
%% Returns: {ok,  [#ontology_class]} |
%%          {error, Reason}
compile_lines(Accumulator, _, []) ->
    {ok, lists:flatten(lists:reverse(Accumulator))};
compile_lines(Accumulator, OntoName,
              [{function, _, class, _, Clauses} | Tail]) ->
    compile_lines([compile_clauses([], Clauses)
                   | Accumulator],
                  OntoName, Tail);
compile_lines(Accumulator, OntoName,
              [{attribute, _, ontology, OntoName} | Tail]) ->
    compile_lines(Accumulator, OntoName, Tail);
compile_lines(_Accumulator, _OntoName,
              [{attribute, Line, ontology, _} | _Tail]) ->
    {error,
     {"ontology name does not match with filename "
      "in line",
      Line}};
compile_lines(Accumulator, OntoName,
              [{attribute, _, file, _} | Tail]) ->
    compile_lines(Accumulator, OntoName, Tail);
compile_lines(Accumulator, OntoName,
              [{eof, _} | Tail]) ->
    compile_lines(Accumulator, OntoName, Tail);
compile_lines(_Accumulator, _,
              [{_, Line, _, _} | _Tail]) ->
    {error, {"syntax error in line", Line}}.

%% @doc compile function clauses (classes) of the ontology,
%%              given its erlang abstract form
%% Returns: [#ontology_class]
compile_clauses(Acc, []) -> lists:reverse(Acc);
compile_clauses(Acc, [H | T]) ->
    compile_clauses([compile_clause(H) | Acc], T).

%% @doc compile a single function clause (classes) of the ontology,
%%              given its erlang abstract form
%% Returns: #ontology_class
compile_clause({clause, _, [{atom, _, ClassName}],
                [], [{tuple, _, ClassDef}]}) ->
    #ontology_class{name = ClassName, superclass = nil,
                    properties =
                        compile_properties([], ClassName, ClassDef)};
compile_clause({clause, _, [{atom, _, ClassName}],
                [],
                [{call, _, {atom, _, is_a},
                  [{atom, _, SuperClass}]}]}) ->
    #ontology_class{name = ClassName,
                    superclass = SuperClass, properties = []};
compile_clause({clause, _, [{atom, _, ClassName}],
                [],
                [{call, _, {atom, _, is_a}, [{atom, _, SuperClass}]},
                 {tuple, _, ClassDef}]}) ->
    #ontology_class{name = ClassName,
                    superclass = SuperClass,
                    properties =
                        compile_properties([], ClassName, ClassDef)}.

%% @doc compile the properties of an ontology class,
%%              given the erlang abstract form
%% Returns: [#ontology_property]
compile_properties(Acc, _, []) -> lists:reverse(Acc);
compile_properties(Acc, ClassName, [H | T]) ->
    compile_properties([compile_property(ClassName, H)
                        | Acc],
                       ClassName, T).

%% @doc compile a single property of an ontology class,
%%              given the erlang abstract form
%% Returns: #ontology_property
compile_property(_ClassName,
                 {match, _, {atom, _, FieldName}, FieldDef}) ->
    L = cons_to_erl_list(FieldDef),
    %%io:format ("~p~n", [L]),
    [FieldType, FieldRequirement, Default | _] = L,
    #ontology_property{name = FieldName, type = FieldType,
                       requirement = FieldRequirement,
                       is_primitive = is_primitive(FieldType),
                       is_digit = is_digit(FieldName), default = Default}.

%% @doc transforms a "cons" abstract erlang construct to a list
%% Returns: [term()]
cons_to_erl_list({cons, _Line, OP1, OP2}) ->
    [cons_decode(OP1) | cons_to_erl_list(OP2)];
cons_to_erl_list(X) -> [cons_decode(X)].

%% @doc decodes a single abstract erlang term
%% Returns: term()
cons_decode({atom, _, nodefault}) -> ?NO_DEFAULT;
cons_decode({atom, _, Option}) -> Option;
cons_decode({nil, _}) -> nil;
cons_decode({call, _, {atom, _, set_of},
             [{atom, _, Type}]}) ->
    {set_of, Type};
cons_decode({call, _, {atom, _, sequence_of},
             [{atom, _, Type}]}) ->
    {sequence_of, Type};
cons_decode({call, _, {atom, _, default},
             [{atom, _, Value}]}) ->
    Value.

%% @doc checks if a type is primitive
%% Returns: true | false
is_primitive(string) -> true;
is_primitive(number) -> true;
is_primitive(integer) -> true;
is_primitive(boolean) -> true;
is_primitive(any) -> true;
is_primitive({sequence_of, X}) -> is_primitive(X);
is_primitive({set_of, X}) -> is_primitive(X);
is_primitive(_) -> false.

%% @doc checks if a slot name is a digit
%% Returns: true | false
is_digit('0') -> true;
is_digit('1') -> true;
is_digit('2') -> true;
is_digit('3') -> true;
is_digit('4') -> true;
is_digit('5') -> true;
is_digit('6') -> true;
is_digit('7') -> true;
is_digit('8') -> true;
is_digit('9') -> true;
is_digit(_) -> false.

%% @doc resolves the inheritances in the list of #ontology_class
%% Returns: [#ontology_class]
resolve_inheritance(Classes) ->
    case resolve_inheritance([], Classes, Classes) of
        {false, NewClassList} ->
            resolve_inheritance(NewClassList);
        {true, NewClassList} -> NewClassList
    end.

%% @doc resolves the inheritances in the list of #ontology_class
%% Returns: {Solved, [#ontology_class]}
resolve_inheritance(Acc, _, []) ->
    {true, lists:reverse(Acc)};
resolve_inheritance(Acc, Classes,
                    [Class = #ontology_class{superclass = nil} | T]) ->
    resolve_inheritance([Class | Acc], Classes, T);
resolve_inheritance(Acc, Classes, [Class | T]) ->
    SuperClass = get_class(Class#ontology_class.superclass,
                           Classes),
    NewClass = Class#ontology_class{properties =
                                        lists:foldl(fun (X, Acc1) ->
                                                            override_property([],
                                                                              Acc1,
                                                                              X)
                                                    end,
                                                    SuperClass#ontology_class.properties,
                                                    Class#ontology_class.properties),
                                    superclass = nil},
    {false, lists:reverse([NewClass | Acc]) ++ T}.

override_property(Acc, [], _) -> lists:reverse(Acc);
override_property(Acc,
                  [#ontology_property{name = N} | T],
                  Property = #ontology_property{name = N}) ->
    override_property([Property | Acc], T, Property);
override_property(Acc, [P | T], Property) ->
    override_property([P | Acc], T, Property).

%% @doc Searches for a class in the list
%% Returns: #ontology_class
get_class(_ClassName, []) -> nil;
get_class(ClassName,
          [Class = #ontology_class{name = ClassName} | _]) ->
    Class;
get_class(ClassName, [_ | T]) ->
    get_class(ClassName, T).

%% @doc generates the tree of hierarchies
%% Returns: [{classname, [classname]}]
generate_hierarchy_tree(Acc, [], _) ->
    lists:reverse(Acc);
generate_hierarchy_tree(Acc, [Class | T], Classes) ->
    Item = {Class#ontology_class.name,
            ancestors_list([], Class#ontology_class.superclass,
                           Classes)},
    generate_hierarchy_tree([Item | Acc], T, Classes).

ancestors_list(Acc, nil, _Classes) -> lists:reverse(Acc);
ancestors_list(Acc, X, Classes) ->
    C = get_class(X, Classes),
    ancestors_list([X | Acc], C#ontology_class.superclass,
                   Classes).

reverse_hierarchy_tree(Acc, [], _) ->
    lists:reverse(Acc);
reverse_hierarchy_tree(Acc, [{Father, _} | T],
                       Classes) ->
    Item = {Father, child_list(Father, Classes)},
    reverse_hierarchy_tree([Item | Acc], T, Classes).

child_list(Father, Classes) ->
    [C
     || {C, Ancestors} <- Classes,
        lists:member(Father, Ancestors)].

%% @doc generates the include file from a list of #ontology_class
%% Returns: [string()]
generate_include_file(Classes) ->
    generate_include_file([], Classes).

generate_include_file(Acc, []) ->
    lists:flatten(lists:reverse(Acc));
generate_include_file(Acc, [Class | T]) ->
    Head = io_lib:format("-record('~s',{~n",
                         [Class#ontology_class.name]),
    Properties = generate_include_lines([],
                                        Class#ontology_class.properties),
    Line = lists:flatten([Head, Properties, "\n"]),
    generate_include_file([Line | Acc], T).

%% @doc generates the lines of properties for an include file
%% Returns: [string()]
generate_include_lines(Acc, []) ->
    Line = io_lib:format("}).~n", []),
    lists:reverse([Line | Acc]);
generate_include_lines(Acc,
                       [Property = #ontology_property{default =
                                                          ?NO_DEFAULT}]) ->
    Line = io_lib:format("  '~s'",
                         [Property#ontology_property.name]),
    generate_include_lines([Line | Acc], []);
generate_include_lines(Acc,
                       [Property = #ontology_property{default = ?NO_DEFAULT}
                        | T]) ->
    Line = io_lib:format("  '~s',~n",
                         [Property#ontology_property.name]),
    generate_include_lines([Line | Acc], T);
generate_include_lines(Acc, [Property]) ->
    Line = io_lib:format("  '~s' = '~s'",
                         [Property#ontology_property.name,
                          Property#ontology_property.default]),
    generate_include_lines([Line | Acc], []);
generate_include_lines(Acc, [Property | T]) ->
    Line = io_lib:format("  '~s' = '~s',~n",
                         [Property#ontology_property.name,
                          Property#ontology_property.default]),
    generate_include_lines([Line | Acc], T).

%% @doc generates the lines for 'childof' functions
%% Returns: [string()]
generate_childof(Acc, []) ->
    lists:flatten(lists:reverse(["childof (_) -> exit (undef_class).\n\n"
                                 | Acc]));
generate_childof(Acc,
                 [{FatherClassName, Children} | T]) ->
    Line =
        lists:flatten(io_lib:format("childof ('~s') -> ~p;\n",
                                    [FatherClassName, Children])),
    generate_childof([Line | Acc], T).

%% @doc generates the lines for 'is_a' functions
%% Returns: [string()]
generate_is_a(Acc, []) ->
    lists:flatten(lists:reverse(["is_a (_,_) -> false.\n\n"
                                 | Acc]));
generate_is_a(Acc, [{_ClassName, []} | T]) ->
    generate_is_a(Acc, T);
generate_is_a(Acc, [{ClassName, Ancestors} | T]) ->
    Line =
        [lists:flatten(io_lib:format("is_a ('~s','~s') -> true;\n",
                                     [ClassName, Ancestor]))
         || Ancestor <- Ancestors],
    generate_is_a([Line | Acc], T).

%% @doc generates the lines for 'is_class' functions
%% Returns: boolean
generate_is_class(Acc, []) ->
    lists:flatten(lists:reverse(["is_class (_) -> false.\n\n"
                                 | Acc]));
generate_is_class(Acc, [{ClassName, _} | T]) ->
    Line =
        lists:flatten(io_lib:format("is_class ('~s') -> true;\n",
                                    [ClassName])),
    generate_is_class([Line | Acc], T).

%% @doc generates the lines for cast functions
%% Returns: [string()]
generate_cast({Acc1, Acc2}, [], _) ->
    {lists:reverse(Acc1), lists:reverse(Acc2)};
generate_cast({Acc1, Acc2}, [{_ClassName, []} | T],
              ResolvedClasses) ->
    generate_cast({Acc1, Acc2}, T, ResolvedClasses);
generate_cast({Acc1, Acc2}, [{ClassName, Children} | T],
              ResolvedClasses) ->
    Lines = lists:flatten([generate_cast_1(V1, ClassName,
                                           ResolvedClasses)
                           || V1 <- Children]),
    [CR, CR, _ | ReversedList] = lists:reverse(Lines),
    %% replace last semicolon with a dot to end the clause
    NewLines = lists:reverse([CR, CR, $. | ReversedList]),
    generate_cast({[ClassName | Acc1], [NewLines | Acc2]},
                  T, ResolvedClasses).

generate_cast_1(X, ClassName, ResolvedClasses) ->
    DestinationClass = get_class(ClassName,
                                 ResolvedClasses),
    SourceClass = get_class(X, ResolvedClasses),
    generate_translation_lines(SourceClass,
                               DestinationClass).

generate_translation_lines(SourceClass,
                           DestinationClass) ->
    Lines =
        [lists:flatten(io_lib:format("    '~s' = X#'~s'.'~s'",
                                     [X#ontology_property.name,
                                      SourceClass#ontology_class.name,
                                      X#ontology_property.name]))
         || X <- DestinationClass#ontology_class.properties],
    XLines = lists:foldl(fun (X, Sum) ->
                                 lists:concat([Sum, ",\n", X])
                         end,
                         "", Lines),
    [_, _ | YLines] = XLines,
    Head =
        lists:flatten(io_lib:format("'~s' (X = #'~s'{}) ->\n  #'~s'{\n",
                                    [DestinationClass#ontology_class.name,
                                     SourceClass#ontology_class.name,
                                     DestinationClass#ontology_class.name])),
    lists:concat([Head, lists:flatten(YLines), "};\n\n"]).
