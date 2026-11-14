# nova_liveboard

Real-time BEAM VM dashboard for [Nova](https://novaframework.org) - a
self-hosted, dependency-light "mission control" for a running node. Built on
**Nova + [Datastar](https://data-star.dev)**: server-rendered HTML, live
updates over SSE, no JavaScript build step, no off-origin requests.

## What it shows

| Page | Live view |
|------|-----------|
| Overview | OTP/ERTS, schedulers, capacity gauges, memory breakdown |
| Metrics | sparklines (memory, run queue, IO) + scheduler utilisation |
| Processes | top processes by memory / reductions / message queue |
| Requests | every HTTP request the node handles, streaming in live, with an opt-in deep trace of the **processes each request spawns** |
| Supervisors | the live supervision tree per application |
| Applications / ETS / Ports | running apps, ETS tables, open ports |
| Database / Schemas | Kura repos, pools and schemas (when Kura is present) |

The vitals deck across the top stays live on every page.

## Install

Add it as a Nova app in your release and mount it via `nova_apps`:

```erlang
{deps, [
    {nova_liveboard,
        {git, "https://github.com/novaframework/nova_liveboard.git", {branch, "master"}}}
]}.
```

```erlang
%% your sys.config
{your_app, [{nova_apps, [nova_liveboard]}]}.
{nova_liveboard, [
    {prefix, "/liveboard"},
    {auth, {your_app_liveboard_auth, operators_only}}
]}.
```

Open `/liveboard`.

`auth` is required: without it Nova does not start. See
[Authentication](#authentication-required).

`nova_liveboard` must be a started application (list it in your release or
`.app.src`): it owns the request tracer and the process that feeds the live
streams.

## Request tracing

The Requests page needs the tracing plugin, registered globally so it sees
every route on the node:

```erlang
{nova, [{plugins, [
    {pre_request,  nova_liveboard_trace_plugin, #{}},
    {post_request, nova_liveboard_trace_plugin, #{}}
]}]}.
```

The request feed (method, path, status, duration, reductions, handler) is
always on and cheap. "Arm next 10" turns on scoped process tracing for the next
few requests, so you can open a request and see the exact tree of processes it
spawned - overhead is only paid while armed.

## Configuration

| Key | Default | Meaning |
|-----|---------|---------|
| `auth` | no default, **required** | who may reach the liveboard, see [Authentication](#authentication-required) |
| `prefix` | `"/liveboard"` | mount path. Set it here only: a `prefix` on the `nova_apps` entry is prepended on top of it and breaks the liveboard's links |
| `refresh_ms` | `2000` | repaint interval for polled streams |
| `request_buffer` | `200` | recent requests retained |
| `max_streams` | `50` | live streams open at once, over all viewers. Each open page uses two. Further streams get `503`; the page still renders, it just does not update |
| `stream_lifetime_ms` | `300000` | how long one live stream stays open before the browser reconnects and is authenticated again |
| `redact` | `standard` | what of request paths, port names and child ids is masked, see [Redaction](#redaction) |
| `trusted_origins` | `[]` | extra origins accepted for actions, see [Actions and CSRF](#actions-and-csrf) |

## Security

### Who the liveboard is for

The liveboard describes the inside of a running node to whoever can open it.
Treat it as an operator tool: put it behind authentication and give access
only to people who are allowed to inspect production. It has no users, roles
or read-only mode of its own.

What a viewer can see:

- the OTP and ERTS versions, the architecture, scheduler, process, port, atom
  and memory figures;
- the top 50 processes: pid, registered name, memory, reductions, message
  queue length and current function;
- every ETS table: name, id, type, protection, size, memory and owner;
- every running application with its version and description;
- every port: id, name, connected process and bytes in and out;
- the supervision tree of any running application: child ids, pids, status
  and memory;
- with the tracing plugin, the method, path, status, duration, reductions,
  memory and handler of every request the node handles outside the liveboard
  itself, and for deep-traced requests the processes they spawned;
- with Kura, each repo's database name, host, port and pool figures, and each
  schema's table, fields and types.

What it never reads or shows: process state, process dictionaries and
messages, the contents of ETS tables, application environments, request
headers, bodies and query strings, and database users and passwords.

What a viewer can do: arm and disarm deep trace for the next ten requests,
and clear the request feed. Deep trace costs the traced requests some speed.
Nothing else on the node can be changed from the liveboard.

Method and path of a traced request are chosen by whoever sends it, so all
output is escaped and nothing dynamic is ever part of a script expression.

### Authentication (required)

The liveboard does not mount until the host has decided who may reach it.
`auth` must be one of:

- `{Module, Function}` - a Nova security callback (the `security` value of a
  route group). The liveboard puts `fun Module:Function/1` on its route group,
  so Nova calls it before every page, stream, action and asset request. It
  returns `true` or `{true, AuthData}` to let the request through, or
  `{false, Status, Headers}` / `{redirect, Path}` to stop it.
- `none` - the explicit opt-out, for a liveboard that is already protected
  some other way (a private listener, an authenticating reverse proxy). The
  liveboard logs a warning when it mounts like this.

With `auth` missing or set to anything else, building the routes fails with
`{nova_liveboard_refusing_to_mount, Reason}` and Nova does not start. A
callback that is not an exported `Module:Function/1` is rejected the same way.

A complete callback using HTTP basic auth:

```erlang
-module(your_app_liveboard_auth).
-export([operators_only/1]).

operators_only(Req) ->
    case
        {application:get_env(your_app, liveboard_login), cowboy_req:header(~"authorization", Req)}
    of
        {{ok, {User, Password}}, <<"Basic ", Given/binary>>} when
            is_binary(User), is_binary(Password)
        ->
            Expected = base64:encode(<<User/binary, ":", Password/binary>>),
            same(Given, Expected) orelse challenge();
        _ ->
            challenge()
    end.

challenge() ->
    {false, 401, #{~"www-authenticate" => ~"Basic realm=\"liveboard\""}}.

same(A, B) ->
    crypto:hash_equals(crypto:hash(sha256, A), crypto:hash(sha256, B)).
```

An app with sessions would instead check the session and redirect to its login
page:

```erlang
operators_only(Req) ->
    case nova_session:get(Req, ~"role") of
        {ok, ~"operator"} -> true;
        _ -> {redirect, "/login"}
    end.
```

With Nova v0.18.3 a `secure` option on the `nova_apps` entry
(`{nova_liveboard, #{secure => fun my_auth:check/1}}`) replaces the
liveboard's callback, and `auth` must still be set. That includes
`secure => false`: it turns the liveboard's callback off, so never set it for
this app.

The callback runs when a request arrives. A live stream is therefore checked
when it opens and again each time it reconnects, at the latest every
`stream_lifetime_ms`.

### Actions and CSRF

The three trace and clear routes are `POST` only and are refused with `403`
unless the request

- is same-origin: `Sec-Fetch-Site: same-origin`, or, when the browser does not
  send that header, an `Origin` naming the host the request was sent to, and
- carries the `x-csrf-token` header with the value of the
  `nova_liveboard_csrf` cookie.

Pages issue the cookie (`HttpOnly`, `SameSite=Strict`, scoped to the prefix,
`Secure` over HTTPS) and the buttons send the token back, so nothing needs to
be configured. Scripts cannot drive the liveboard with a bare `POST`; call
`nova_liveboard_tracer` from your own code instead.

Current browsers omit `Sec-Fetch-Site` only over plain HTTP on a host other
than localhost. If the liveboard is served that way behind a proxy that
rewrites `Host`, list the public origin:

```erlang
{trusted_origins, [~"http://ops.internal.example"]}
```

### Redaction

Three of the values shown can carry a secret: the path of a traced request (a
reset token, an API key, a signed link), the name of a port (for a spawned
program its whole command line) and a supervisor child id that is not an atom
(printed as a term, often built from a connection configuration). `redact`
decides what is masked:

- `standard` (the default) - a path segment of 20 or more bytes that contains
  a digit is shown as `[redacted]`, so `/reset/9f86d081884c7d659a2feaa0c55ad015`
  becomes `/reset/[redacted]`; a port name is cut after the program, so
  `psql postgres://app:secret@db/prod` becomes `psql [redacted]`; a child id is
  printed, capped at 200 characters.
- `none` - the three are shown as they are, capped in length.
- `all` - each of the three is shown as `[redacted]`.
- `{Module, Function}` - `Module:Function(Kind, Value)` is called with
  `request_path`, `port_name` or `child_id` and the value as a binary, and
  returns the binary to show. If it returns anything else or fails, the value
  is shown as `[redacted]`.

```erlang
-module(your_app_liveboard_redact).
-export([shown/2]).

shown(request_path, <<"/files/", _/binary>>) -> ~"/files/:name";
shown(port_name, _Name) -> ~"a port";
shown(_Kind, Value) -> Value.
```

```erlang
{redact, {your_app_liveboard_redact, shown}}
```

A path is redacted when the request is captured, so the tracer never holds the
original, and the query string is never captured at all.

The `standard` rule is a guess at what a token looks like. A short secret in a
path is shown, so use `all` or a callback when the default is not enough.

### Live streams

One process renders each distinct view once per `refresh_ms` and sends the
frame to every stream showing it, so the work done inspecting the node follows
the number of different views open, not the number of browsers. The Requests
view is repainted at most five times a second, however busy the node is. No
more than `max_streams` streams are open at once and each one ends after
`stream_lifetime_ms`; the browser reconnects by itself.

The limit is shared by all viewers: there is no per-viewer quota, so with
`auth` set to `none` anyone who can reach the listener can use up the streams.
Pages still render when they are used up.

### Browser policy

Pages are sent with `Content-Security-Policy: default-src 'none'` plus
same-origin script, style, font, image, connect and form sources,
`frame-ancestors 'none'`, `X-Content-Type-Options: nosniff` and
`Cache-Control: no-store`. `script-src` includes `'unsafe-eval'` because
Datastar compiles its attribute expressions at runtime; inline scripts and
inline styles stay blocked.

## Privacy

Fonts, CSS and datastar.js are all self-hosted under `priv/static/assets` and
served from the liveboard's own routes, never from a CDN. Nothing is fetched
off-origin.

## Requirements

Nova must be v0.17.0 or later; the liveboard pins v0.18.3. Older routers do
not resolve `.` and `..` in a request path before matching it.

## Licence

Apache-2.0.
