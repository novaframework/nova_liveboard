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
{nova_liveboard, [{prefix, "/liveboard"}]}.
```

Open `/liveboard`.

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
| `prefix` | `"/liveboard"` | mount path |
| `refresh_ms` | `2000` | repaint interval for polled streams |
| `request_buffer` | `200` | recent requests retained |

## Privacy

Fonts, CSS and datastar.js are all self-hosted under `priv/static/assets`, and
the dashboard sends a strict `Content-Security-Policy` of `default-src 'self'`.
Nothing is fetched off-origin.

## Licence

Apache-2.0.
