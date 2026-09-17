# Discord Telemetry

`ScribeTelemetry` sends Scribe's health reports, errors and selected warnings to
Discord. You can also enable performance alerts and regular summaries.

It is an optional add-on, **not part of the Scribe package**. Scribe sends nothing
to Discord unless you install and start it.

Before you begin:

1. Set up Scribe using [Getting Started](./intro).
2. Copy the `ScribeTelemetry` folder from
   [`addons/telemetry/`](https://github.com/ericplane/Scribe/tree/main/addons/telemetry)
   into `ServerStorage`, or insert `ScribeTelemetry-Addon.rbxm` from the
   [release page](https://github.com/ericplane/Scribe/releases) there.
3. Enable **HTTP Requests** in Experience Settings.
4. Create a Discord webhook for the channel that should receive reports.

## One webhook

```lua
-- ServerScriptService/EmberfallTelemetry.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Scribe = require(ReplicatedStorage.Packages.Scribe)
local ScribeTelemetry = require(ServerStorage.ScribeTelemetry)

local telemetry = ScribeTelemetry.Start(Scribe, {
    Webhooks = {
        Alerts = { Url = "https://discord.com/api/webhooks/<id>/<token>" },
    },
    Default = "Alerts",
})
```

Put this script beside your Scribe server setup. Replace `<id>` and `<token>` with
your webhook's values. All enabled report categories go to `Alerts`.

By default, you receive health reports, errors, fatal errors and selected warnings.
Performance alerts and regular summaries need extra configuration below.

!!! warning "Keep the webhook URL private"
    Anyone with the URL can post to your channel. Store it in a server script or
    `ServerStorage`, never in `ReplicatedStorage`. The add-on redacts configured
    webhook URLs from the messages it sends.

!!! note "Testing in Studio"
    The add-on sends nothing from Studio unless you add `AllowStudio = true` to
    the options passed to `Start`. Without it, the handle's state is
    `DisabledInStudio`. Use a separate test channel when trying the previews below.

!!! warning "Discord refuses Roblox servers"
    Discord answers requests from Roblox's datacenter ranges with HTTP 403. A
    webhook that works from Studio may therefore fail in a published server.
    Route these requests through a proxy: replace the host and keep
    `/api/webhooks/<id>/<token>`.

    ```lua
    Alerts = { Url = "https://<proxy host>/api/webhooks/<id>/<token>" },
    ```

    **The proxy can see your token.** Host it yourself or choose one you trust.
    The community-run [WebhookProxy](https://github.com/lewisakura/webhook-proxy)
    is one option and applies Discord's rate limits.

    A 403 from `discord.com` disables that destination and drops its queue.
    `GetStats().Destinations.<name>.LastError` explains that a proxy is needed.

## Lifecycle

The first example saves the handle returned by `Start` as `telemetry`. Use it
for these separate tasks:

| Call | Purpose |
| --- | --- |
| `telemetry:Test("Alerts")` | Queue one test message; returns `(ok, reason)`. |
| `telemetry:Preview("Alerts", "All")` | Queue synthetic examples of every report; returns `(ok, reason)`. |
| `telemetry:Flush(5)` | Wait up to five seconds for the queues to drain. |
| `telemetry:GetStats()` | Read queue, delivery and destination state, without URLs. |
| `telemetry:Stop()` | Remove the log sink and status connection. Calling it again is safe. |

`Start` checks the configuration before connecting listeners. It errors for:

- A URL that does not use `http` or `https`.
- A route to an unknown destination, or an empty route list.
- A role ID containing anything other than digits.
- A performance rule with no threshold.

You cannot start a second handle for the same Scribe module until the first one
has stopped.

## Previewing every design

Use `Preview` to see the report designs without causing an outage or changing
player data. Keep the handle returned by `Start`, then call:

```lua
telemetry:Preview("Alerts")            -- every scenario
telemetry:Preview("Alerts", "Health")  -- one group
telemetry:Preview("Alerts", "Outage")  -- one scenario
```

Every preview title starts with `PREVIEW:`, and each embed says its data is
synthetic. **Previews never mention a role or change the add-on's view of the
server.** To try them in Studio, start the add-on with `AllowStudio = true`.

| Result | Meaning |
| --- | --- |
| `(true)` | All requested examples were queued. This does not confirm delivery. |
| `(false, reason)` | A kind or destination was unknown, the destination was disabled or dead, a queue was full, or the add-on was stopped or disabled in Studio. |

Previews use the same formatting and delivery queue as real reports. Your rate
limits and configured `Limits` still apply. They appear in
`GetStats().Previews`, separately from `Reports`.

| Kind | Scenarios |
| --- | --- |
| `Health` | `HealthyStartup`, `Degraded`, `Outage`, `PartialRecovery`, `Recovery`, `IncidentUnderway` |
| `Issues` | `Error`, `Fatal` |
| `Warnings` | `Warning` |
| `Grouping` | `Repeat`, `UpstreamSuppressed` |
| `Performance` | `SlowSaves`, `SaveFailures`, `Traffic`, each with a `Cleared` counterpart |
| `Summaries` | `Summary`, `SummaryNoSamples`, `SummaryNoBudget` |
| `Formatting` | `LongMessage`, `RedactedContext` |

The [Scribe Studio plugin](./studio-plugin) also offers previews under
**Diagnostics → Simulations**. Choose a destination and a kind, then enable the
plugin's write toggle. The preview button is enabled when writes are on and a
started add-on reports `Running`; otherwise, its tooltip explains what is missing.

??? note "What previews leave unchanged"
    Previews use the real report builders without changing summary baselines,
    performance streaks, repeat groups or mention cooldowns.

    The add-on registers itself with `Scribe.RegisterAddon` when it starts, even
    when Studio has disabled it. That makes the plugin's preview row visible, but
    `AllowStudio = true` is still required to send from Studio.

## Separate channels

Give each webhook a name, then use `Routes` to choose which reports it receives.
In this example, health reports and summaries have their own channels, while
performance alerts go to two channels.

Use this configuration in place of the one-webhook example; do not start both.

A category without a route uses `Default`. Setting its route to `false` disables
it; it does not fall back to `Default`.

```lua
ScribeTelemetry.Start(Scribe, {
    Webhooks = {
        Alerts = {
            Url = "https://discord.com/api/webhooks/<id>/<token>",
            Mention = { RoleId = "123456789012345678" },
        },
        Health = { Url = "https://discord.com/api/webhooks/<id>/<token>" },
        Summaries = { Url = "https://discord.com/api/webhooks/<id>/<token>" },
    },
    Default = "Alerts",
    Routes = {
        Health = "Health",
        Summaries = "Summaries",
        Performance = { "Alerts", "Health" },
        Warnings = false,
    },
    Summaries = { Enabled = true, Interval = 1800 },
    Performance = {
        Rules = {
            SlowSaves = { Threshold = 2 },
            SaveFailures = { Threshold = 1 },
        },
    },
})
```

With `Mention` configured, `Fatal` and `Outage` reports can ping the role. By
default, a destination can ping at most once every five minutes; routine reports
do not ping. Use `Mention.On` to choose other report kinds and `Mention.Cooldown`
to change the interval.

If two destination names use the same URL, each report is delivered there once.

## The five categories

| Category | What it reports | Default |
| --- | --- | --- |
| `Health` | Degraded service, outages and recovery. | On |
| `Issues` | `Error` and `Fatal` log entries. | On |
| `Warnings` | Selected `Warn` entries. | On, selected codes only |
| `Performance` | A configured threshold is exceeded, or the condition clears. | Off until a rule has a threshold |
| `Summaries` | Regular health, usage and performance reports. | Off |

Every report describes **this server**. An outage report says what this server
observed; it is not a verdict on your whole game. Reports are not combined across
servers, so ten servers in an outage can send ten reports.

### Choosing reports

`Health` listens to [`OnStatusChanged`](/api/Scribe#OnStatusChanged). Reports name
the transition—degraded service, outage, partial recovery or full recovery—and
how long the previous state was observed. If an incident
was already underway when telemetry started, the report says so without guessing
its start time.

`Issues` includes all errors and fatal errors except those listed in
`Issues.ExcludeCodes` or `Issues.ExcludeCategories`.

`Warnings` includes a warning when its code is in `Warnings.Include` or its
category is in `Warnings.Categories`. The default code list is available as
`ScribeTelemetry.DefaultWarningCodes`. It focuses on warnings you may need to
act on: profiles nearing the 4 MB limit, slow loads, held or forced saves, dropped receipt IDs or
purchase claims, unconfirmed gifts or passes, and lost leaderboard writes.

### Performance rules and summaries

A performance rule must hold for `Performance.Checks` consecutive checks, taken
`Performance.Interval` seconds apart. It sends another report when the condition
clears. Each enabled rule needs a `Threshold`.

| Rule | Threshold measures |
| --- | --- |
| `SlowSaves` | p99 (99th percentile) save duration, in seconds. Each check needs `MinSamples` fresh samples. |
| `SaveFailures` | Save failures per minute. |
| `Traffic` | `BytesOut` per second. |

Summaries run every `Summaries.Interval` seconds. They include health, sessions,
loads and saves during the interval, and outgoing bytes per second. Save-duration
and profile-size percentiles show the time windows they cover. The DataStore
budget is included when the server can read it.

### Repeated reports

The first occurrence of a code is reported immediately. Further occurrences are
grouped into a follow-up after `Grouping.Interval` (60 seconds by default). When
an entry identifies a player or key, each subject has its own group.

The count is how many entries telemetry saw. Scribe may already have suppressed
some repeated logs; their `Repeats` context value is reported separately. In that
case, the follow-up says the underlying total is higher instead of claiming an
exact count.

## What a message carries

Each message uses Scribe's name and logo. The branding is fixed; `Start` rejects
`IconUrl` and `BrandName` options.

The footer includes a report ID, place version, your configured `Environment` and
the time in UTC. Discord also displays the time in your local zone. The report
ID combines the first eight characters of the server ID with a counter.

Live-server messages include a `Server` link that joins that server, provided it
has a place ID and `JobId`. Studio messages omit the join link. Health reports and
summaries also include the place ID and Scribe version.

### Player privacy

**Player identifiers are redacted by default.** Set `IncludePlayerIds = true`
only if you want them included in reports sent to your endpoint.

With the default setting:

- Non-table values under player context fields become `[player]`. Recognized
  names include `UserId`, `RecipientId`, `BuyerId`, `Player`, and names ending in
  `UserId` or `PlayerId`. The same rules apply inside retained nested tables.
- `UserId=...`, `Player=...`, and `Player` instances in log context are also
  redacted as `[player]`.
- Non-table values under context fields named `Key` or ending in `Key`, plus
  grouping subjects built from them, become `[key]`. Profile keys can contain
  player identifiers even without a recognizable prefix.
- Keys in message text lose their digits when they use the configured
  `ProfileKeyPrefix` or another prefix ending in an underscore. The add-on asks
  Scribe for its current prefix on every entry.

Context tables are limited to twelve keys and two levels. Functions, threads and
unsupported Roblox values are dropped. Non-player instances are reduced to their
class and name. Text is shortened at a valid UTF-8 boundary to fit Discord's limits.

## Delivery

**Delivery is best effort: reports can be dropped.** HTTP requests run in a
delivery worker, so a slow endpoint does not block Scribe. Each log sink also runs
in its own thread. One failing webhook does not hold up another.

Queues have these default limits:

| Option | Default |
| --- | --- |
| `Limits.PerDestination` | 64 reports per destination |
| `Limits.MaxQueued` | 200 reports overall |
| `Limits.MaxQueuedBytes` | 256 KB overall |
| `Limits.MaxAge` | 15 minutes |
| `Limits.MaxAttempts` | 5 delivery attempts |

When a queue is full, it drops the oldest expired report first. Otherwise, it
drops the lowest-priority report whose priority is no higher than the incoming
one. A summary can make room for an issue; an issue is never dropped to make room
for a summary. Reports older than `Limits.MaxAge` are dropped.

### HTTP responses and retries

| Response | What the add-on does |
| --- | --- |
| Any `2xx` | Counts delivery as successful. |
| `429`, or `X-RateLimit-Remaining: 0` | Respects the destination's rate limit. |
| `5xx` or a network error | Retries with increasing delays, up to `Limits.MaxAttempts`. |
| `401`, `403`, `404` or `410` | Marks the destination dead and drops its queue. |
| `400`, `413` or `422` | Drops the invalid report without retrying it. |

A timed-out request is counted as `Uncertain`: it may have reached the endpoint
even though the response did not arrive. Use `GetStats()` to inspect delivery and
per-destination state without exposing the configured URLs.

## Custom endpoints

You can send reports to your own service instead of a Discord webhook. `Url`
accepts an `http` or `https` URL with a host name or IP address, such as
`https://api.example.com/telemetry/alerts`.

The service receives Discord's JSON format as `application/json`:
`username`, `avatar_url`, `embeds`, `allowed_mentions`, and `content` when a
mention is included. Return any `2xx` status to acknowledge delivery. The response
and retry rules above apply to every host.

The add-on adds `wait=true` only to URLs with Discord's `/api/webhooks/` path.
Every configured URL is redacted from outgoing messages, including custom URLs.

!!! warning "Use HTTPS for private data"
    Plain `http` sends the message body and any secrets in the URL unencrypted.
    Keep plain HTTP use to an endpoint you own and an environment where that is
    acceptable.

## Types

The add-on uses `--!strict` and exports `Options`, `Handle`, `Stats` and
`ScribeModule`. With Luau's new type solver, the editor can flag misspelt options,
wrong value types, unknown mention kinds and invalid stat access before you run
the script.

??? note "Implementation and type checks"
    The add-on uses only Scribe's public diagnostics API: one log sink, one status
    connection and the metric readers. A game script can access the same signals.

    `test/TypeCheck.luau` checks the exported types, and `test/TypeCheckErrors.luau`
    checks that invalid shapes are rejected.

## Where to next

- [Diagnostics](./diagnostics) is what these reports are made of: the log sink, the health machine and the metric readers.
- [Log Code Reference](./log-codes) lists every code an `Issues` or `Warnings` report can name.
- [Scribe Studio](./studio-plugin) shows the same signals live in a dock while you play-test.
