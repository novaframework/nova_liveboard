-module(nova_liveboard_test_schema).
-moduledoc "A schema as Kura v2.30.0 describes one: its records, written out as tuples.".
-behaviour(kura_schema).

-export([table/0, fields/0, associations/0, indexes/0]).

-spec table() -> binary().
table() ->
    ~"things".

-spec fields() -> [tuple()].
fields() ->
    [
        {kura_field, id, id, undefined, undefined, true, false, false},
        {kura_field, name, string, ~"thing_name", undefined, false, true, false},
        {kura_field, tags, {array, string}, undefined, [], false, true, true}
    ].

-spec associations() -> [tuple()].
associations() ->
    [
        {kura_assoc, owner, belongs_to, nova_liveboard_test_schema, owner_id, undefined, undefined,
            undefined, undefined, undefined},
        {kura_assoc, parts, has_many, nova_liveboard_test_schema, thing_id, undefined, undefined,
            undefined, undefined, delete_all}
    ].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [{[name], #{unique => true}}, {[owner_id, name], #{}}].
