-module(kura_schema).
-moduledoc """
Stands in for Kura's module of the same name, which the liveboard calls when
it finds it in the node. Kura is not a dependency.
""".

-export([associations/1, indexes/1]).

-callback table() -> binary().
-callback fields() -> [tuple()].
-callback associations() -> [tuple()].
-callback indexes() -> [{[atom()], map()}].

-spec associations(module()) -> [tuple()].
associations(Schema) ->
    Schema:associations().

-spec indexes(module()) -> [{[atom()], map()}].
indexes(Schema) ->
    Schema:indexes().
