-module(nova_liveboard_action_controller).
-moduledoc """
POST handlers for the Requests page controls (arm / disarm / clear deep trace).

Each mutates `nova_liveboard_tracer` and returns a one-shot Datastar response:
a normal `{status, 200, ...}` reply whose body is SSE-framed patch events.
Nova's built-in `handle_status` sends it, and Datastar applies the patches to
the clicking client immediately. Other open clients converge via the tracer's
own notifications to their Requests stream.

Every action first passes `nova_liveboard_csrf:verify/1` and is answered with
403, without touching the tracer, when it does not.
""".

-include_lib("kernel/include/logger.hrl").

-export([trace_start/1, trace_stop/1, clear/1]).

-define(ARM_COUNT, 10).

trace_start(Req) ->
    verified(Req, fun() ->
        nova_liveboard_tracer:start_trace(?ARM_COUNT),
        oneshot([toolbar_patch()])
    end).

trace_stop(Req) ->
    verified(Req, fun() ->
        nova_liveboard_tracer:stop_trace(),
        oneshot([toolbar_patch()])
    end).

clear(Req) ->
    verified(Req, fun() ->
        nova_liveboard_tracer:clear(),
        oneshot([toolbar_patch(), feed_cleared_patch()])
    end).

%% ---------------------------------------------------------------------------

verified(Req, Action) ->
    case nova_liveboard_csrf:verify(Req) of
        ok ->
            Action();
        {error, Reason} ->
            ?LOG_NOTICE(#{
                msg => ~"nova_liveboard_csrf_rejected",
                reason => Reason,
                path => maps:get(path, Req, undefined)
            }),
            {status, 403}
    end.

oneshot(Frames) ->
    {status, 200, maps:from_list(datastar:sse_headers()), iolist_to_binary(Frames)}.

toolbar_patch() ->
    datastar:patch_elements(
        nova_liveboard_html:requests_toolbar_html(nova_liveboard_tracer:trace_state()),
        #{selector => ~"#req-toolbar", mode => inner}
    ).

feed_cleared_patch() ->
    datastar:patch_elements(
        ~"<p class=\"empty\">cleared - waiting for the next request</p>",
        #{selector => ~"#req-feed", mode => inner}
    ).
