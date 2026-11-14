-module(nova_liveboard_asset_controller).
-moduledoc """
Serves the liveboard's own static assets.

The assets are a closed set: the stylesheet and the script each have a literal
route, and a font request is looked up by name in a fixed table. Nothing from
the request is used to build a path, so what can be read does not depend on
how the host's Nova version treats `.`, `..` or encoded segments in a request
path.
""".

-export([stylesheet/1, script/1, font/1]).

-define(FONTS, #{
    ~"ibm-plex-mono-latin-400-normal.woff2" =>
        "static/assets/fonts/ibm-plex-mono-latin-400-normal.woff2",
    ~"ibm-plex-mono-latin-400-italic.woff2" =>
        "static/assets/fonts/ibm-plex-mono-latin-400-italic.woff2",
    ~"ibm-plex-mono-latin-500-normal.woff2" =>
        "static/assets/fonts/ibm-plex-mono-latin-500-normal.woff2",
    ~"ibm-plex-mono-latin-600-normal.woff2" =>
        "static/assets/fonts/ibm-plex-mono-latin-600-normal.woff2"
}).

-type reply() ::
    {sendfile, 200, map(), {0, non_neg_integer(), file:filename_all()}, binary()}
    | {status, 404}.

-doc "GET <prefix>/assets/css/app.css".
-spec stylesheet(map()) -> reply().
stylesheet(_Req) ->
    send("static/assets/css/app.css", ~"text/css").

-doc "GET <prefix>/assets/js/datastar.js".
-spec script(map()) -> reply().
script(_Req) ->
    send("static/assets/js/datastar.js", ~"text/javascript").

-doc "GET <prefix>/assets/fonts/:font, for the bundled fonts only.".
-spec font(map()) -> reply().
font(Req) ->
    Name = maps:get(~"font", maps:get(bindings, Req, #{}), undefined),
    case ?FONTS of
        #{Name := Asset} -> send(Asset, ~"font/woff2");
        _ -> {status, 404}
    end.

-spec send(string(), binary()) -> reply().
send(Asset, ContentType) ->
    case code:priv_dir(nova_liveboard) of
        {error, bad_name} ->
            {status, 404};
        PrivDir ->
            Path = filename:join(PrivDir, Asset),
            case filelib:file_size(Path) of
                0 ->
                    {status, 404};
                Size ->
                    Headers = #{~"x-content-type-options" => ~"nosniff"},
                    {sendfile, 200, Headers, {0, Size, Path}, ContentType}
            end
    end.
