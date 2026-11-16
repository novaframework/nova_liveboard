-module(nova_liveboard_test_library).
-moduledoc """
Puts a library the liveboard does not depend on into the node, and takes it
out again, so a test can run with it, without it, and with a version of it
that lacks a function.

The code is that of a test module, compiled again under the library's name.
""".

-export([install/3, remove/1]).

-type form() :: erl_parse:abstract_form() | erl_parse:form_info().

-doc "Loads the code of `Fake` as the module `Library`, without exporting `Hidden`.".
-spec install(module(), module(), [{atom(), arity()}]) -> ok.
install(Library, Fake, Hidden) ->
    {Fake, Beam, _File} = code:get_object_code(Fake),
    {ok, {Fake, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Beam, [abstract_code]),
    Renamed = [Form || Compiled <- Forms, Form <- renamed(Compiled, Library, Hidden)],
    case compile:forms(Renamed, []) of
        {ok, Library, Code} when is_binary(Code) ->
            {module, Library} = code:load_binary(Library, atom_to_list(Library) ++ ".erl", Code),
            ok
    end.

-doc "Takes `Library` out of the node. Nothing happens when it is not there.".
-spec remove(module()) -> ok.
remove(Library) ->
    _ = code:purge(Library),
    _ = code:delete(Library),
    _ = code:purge(Library),
    ok.

-spec renamed(form(), module(), [{atom(), arity()}]) -> [erl_parse:abstract_form()].
renamed({attribute, Anno, module, _Fake}, Library, _Hidden) ->
    [{attribute, Anno, module, Library}];
renamed({attribute, Anno, export, Exported}, _Library, Hidden) when is_list(Exported) ->
    [{attribute, Anno, export, Exported -- Hidden}];
renamed({eof, _Location}, _Library, _Hidden) ->
    [];
renamed({error, _Info}, _Library, _Hidden) ->
    [];
renamed({warning, _Info}, _Library, _Hidden) ->
    [];
renamed(Form, _Library, _Hidden) ->
    [Form].
