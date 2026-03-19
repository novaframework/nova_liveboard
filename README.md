# Nova Liveboard

Real-time BEAM VM dashboard for [Nova](https://github.com/novaframework/nova) — the Erlang equivalent of Phoenix LiveDashboard.

Built on [Arizona](https://github.com/Taure/arizona_core) for live differential rendering over WebSocket.

## Pages

| Page | Description | Refresh |
|------|-------------|---------|
| **System** | OTP release, uptime, schedulers, memory breakdown with usage bars | 2s |
| **Processes** | Top 50 processes by memory/reductions/message queue, sortable | 2s |
| **ETS** | All ETS tables with type, protection, size, memory, owner | 3s |
| **Applications** | Running applications with versions | 5s |
| **Ports** | Open ports with I/O stats | 3s |
| **Supervisors** | App selector with supervision tree visualization | 5s |
| **Metrics** | Live sparkline charts (memory, processes, IO, run queue) + scheduler utilization bars | 2s |

## Setup

Add to your Nova application's `rebar.config`:

```erlang
{deps, [
    {nova_liveboard, {git, "https://github.com/novaframework/nova_liveboard.git", {branch, "master"}}}
]}.
```

Add `nova_liveboard` to your application's dependencies in your `.app.src`:

```erlang
{applications, [kernel, stdlib, nova, nova_liveboard]}
```

Configure the liveboard in your `sys.config`:

```erlang
{nova, [
    {nova_apps, [
        #{name => nova_liveboard, prefix => "/liveboard"}
    ]}
]}
```

Visit `http://localhost:8080/liveboard` in your browser.

## Dependencies

- [Nova](https://github.com/novaframework/nova) — Erlang web framework
- [Arizona Core](https://github.com/Taure/arizona_core) — Live view engine with compile-time template optimization
- [Arizona Nova](https://github.com/Taure/arizona_nova) — Bridge between Arizona and Nova (WebSocket controller, PubSub)

## Architecture

- **Data layer** (`nova_liveboard_data`) — Pure functions collecting VM metrics, supervision trees, scheduler wall time deltas, sparkline point generation
- **Views** — Arizona views with `arizona_parse_transform` for compile-time template optimization
- **WebSocket** — Thin wrapper around `arizona_nova_websocket` with `flatten_reply` to bridge Arizona's list-based frame replies to Nova's single-frame `handle_ws` callback
- **Routing** — Nova router with WebSocket route defined after `/:page` to ensure `routing_tree` matches the exact `/live` path before the binding

## License

Apache-2.0
