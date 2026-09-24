# ScribeTelemetry

Scribe's profile and leaderboard health, failures, selected warnings, performance rules and
periodic summaries, posted to Discord webhooks from the server. Optional and server-only,
using public diagnostics: one log sink, one status connection, metric readers and cached
leaderboard snapshots. It makes no DataStore requests and never changes player data.

**Wally users:** copy the `ScribeTelemetry` folder into `ServerStorage` (or anywhere only the
server can require) and start it from a server script.
Keep webhook configuration in a server script even when the package itself is replicated.

**roblox-ts users:** the separate optional `@rbxts/scribe-telemetry` package includes
the same implementation with typed configuration, destination names, preview kinds,
and statistics, including the leaderboard monitor. See [roblox-ts](../../docgen/guides/roblox-ts.md)
for publication status and [the telemetry guide](../../docgen/guides/telemetry.md#roblox-ts)
for a TypeScript example. Import it from a server script and keep endpoint URLs there.

## Install

1. Copy `addons/telemetry/ScribeTelemetry/` into your game, or insert `ScribeTelemetry-Addon.rbxm`
   from the [release page](https://github.com/ericplane/Scribe/releases), for example at
   `ServerStorage/ScribeTelemetry`.
2. Enable **HTTP Requests** in Game Settings (Security). `HttpService` is what posts to Discord.
3. Create a webhook in the Discord channel that should receive reports (Channel settings,
   Integrations, Webhooks) and copy its URL.
4. Start the add-on beside your Scribe bundle:

```lua
-- ServerScriptService/Telemetry.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Scribe = require(ReplicatedStorage.Packages.Scribe)
local ScribeTelemetry = require(ServerStorage.ScribeTelemetry)

ScribeTelemetry.Start(Scribe, {
    Webhooks = {
        Alerts = { Url = "https://discord.com/api/webhooks/<id>/<token>" },
    },
    Default = "Alerts",
})
```

That is the single-webhook setup: every category goes to `Alerts`. Keep the URL in a server
script or a `ServerStorage` module. It is a credential: anyone holding it can post to the
channel, and the add-on redacts webhook URLs from every message it sends for that reason.

## Discord refuses Roblox servers

Discord answers requests from Roblox's datacenter ranges with HTTP 403. Studio goes out
through your own connection and works, so a webhook that posts in a play-test still fails from
a published server. Route it through a proxy that keeps Discord's path: replace the host and
keep `/api/webhooks/<id>/<token>`.

```lua
Alerts = { Url = "https://<proxy host>/api/webhooks/<id>/<token>" },
```

The proxy sees your token, so host one yourself (a few lines on a Cloudflare Worker) or use
one you trust; the community-run [WebhookProxy](https://github.com/lewisakura/webhook-proxy)
is the usual choice and applies Discord's rate limits itself. A 403 from `discord.com` marks
the destination dead, and `GetStats().Destinations.<name>.LastError` says to use a proxy.

## Your own endpoint

`Url` is any http or https URL with a host, by name or by IP address, so a service of your own
works too:

```lua
Alerts = { Url = "https://api.example.com/telemetry/alerts" },
```

It receives what Discord would: a JSON body with `username`, `avatar_url`, `embeds`,
`allowed_mentions` and, on a mention, `content`, posted with `Content-Type: application/json`.
Answer with any 2xx. The add-on treats status codes the same way for every host (a `429`
paces, a `5xx` retries, a `401`, `403`, `404` or `410` kills the destination), and adds
`wait=true` to the query only on Discord's `/api/webhooks/` path. Every configured URL is
redacted wherever it appears in a message, whatever its shape. Over plain `http` the body
and anything secret in the URL travel unencrypted, so keep that to an endpoint you own.

## Separate channels

Name a destination per channel and route categories to them. A category with no route uses
`Default`; `false` disables one outright.

```lua
ScribeTelemetry.Start(Scribe, {
    Webhooks = {
        Alerts = {
            Url = "https://discord.com/api/webhooks/<id>/<token>",
            Mention = { RoleId = "123456789012345678" }, -- on Fatal and Outage, once per 5 minutes
        },
        Health = { Url = "https://discord.com/api/webhooks/<id>/<token>" },
        Boards = { Url = "https://discord.com/api/webhooks/<id>/<token>" },
        Summaries = { Url = "https://discord.com/api/webhooks/<id>/<token>" },
    },
    Default = "Alerts",
    Routes = {
        Health = "Health",
        Leaderboards = "Boards",
        Summaries = "Summaries",
        Performance = { "Alerts", "Health" },
        Warnings = false,
    },
    Summaries = { Enabled = true, Interval = 1800 },
    Performance = {
        Rules = {
            SlowSaves = { Threshold = 2 }, -- p99 save duration, seconds
            SaveFailures = { Threshold = 1 }, -- failures per minute
        },
    },
})
```

The categories are `Health`, `Leaderboards`, `Issues`, `Warnings`, `Performance` and
`Summaries`. Two names on the same URL deliver a report once.

## What is sent

Every message is an embed. Its footer names the report id (the server's first eight characters and a counter), the place version, the environment and the time in UTC; Discord shows the same time in your zone beside it. A message from a live server, one with a place id and a `JobId`, carries a `Server` field whose link launches the game into that server; Studio has no live server JobId, so its messages omit the join link. Health reports and summaries also carry the place id and the Scribe version.

| Category | When | Default |
| --- | --- | --- |
| `Health` | Profile-service degradation, outage and recovery, with the observed duration. | On |
| `Leaderboards` | A board is first observed degraded, becomes degraded or recovers. | On |
| `Issues` | Errors and fatal errors, minus `Issues.ExcludeCodes` and `Issues.ExcludeCategories`. | On |
| `Warnings` | Codes in `Warnings.Include` or categories in `Warnings.Categories`. | Selected codes |
| `Performance` | A configured rule holds for `Performance.Checks` checks, then when it clears. | Off until configured |
| `Summaries` | Health, activity and performance every `Summaries.Interval` seconds. | Off |

Performance rules are `SlowSaves` (p99 save duration, with `MinSamples` fresh samples),
`SaveFailures` (per minute) and `Traffic` (bytes out per second). Each needs a `Threshold`;
checks run every `Performance.Interval` seconds.

`ScribeTelemetry.DefaultWarningCodes` includes leaderboard read/write failures, overflow and
budget deferrals, slow leaving callbacks and receipt retries. Receipt-history capacity errors
already use `Issues`.

### Leaderboard monitoring and summaries

`Leaderboards = { Enabled = true, Interval = 30, MaxBoards = 64 }` is the default. The interval
has a 5-second minimum. Monitoring runs in the existing telemetry tick and reads
`Scribe.GetLeaderboardSnapshot()` from memory across all active bundles using that module.
It adds no DataStore reads. Reports identify boards by numeric `BundleId` and name.

An initially degraded board sends an alert; later degraded/recovered transitions send another.
`Starting` is quiet, and a disappearing board is removed without a recovery claim.
`Routes.Leaderboards` can target its own channel, use `Default`, or be `false` to suppress alerts.
That route switch leaves monitoring and summaries active; `Leaderboards.Enabled = false`
stops polling. Above `MaxBoards`, the first boards by bundle ID and name are tracked and
summaries report monitored/omitted counts. Omitted boards are not monitored.
Profile health stays separate: a healthy profile service does not promise healthy boards.

Summaries label the shared status **Profile health** and include bounded board details with
backlog and cache age. They identify disabled/unavailable monitoring and omitted boards.
Leaderboard counter deltas, receipt-history refusals, and log-sink drops/errors appear beside
the existing load/save and traffic totals. The last reported queue gauge belongs to the last
reporting bundle, not all bundles combined; per-board pending counts describe each backlog.
Profile-load, total join and leaving-hook duration percentiles join save duration and profile
size, with sample windows shown. Measurements absent from older Scribe versions are omitted.

An older Scribe without the snapshot API still works: it produces no board health reports,
and summaries mark that information unavailable.

Every report describes **this server**. There is no cross-server aggregation and no global
verdict: an outage reported here is the condition this server observed.

Repeats of one code (and subject) are grouped: the first occurrence is reported at once and
later ones fold into a follow-up when `Grouping.Interval` passes. Scribe's own upstream
suppression (`Context.Repeats`) is reported separately from what telemetry saw, and the
follow-up says the underlying total is higher rather than claiming an exact count.

## Privacy defaults

Player identifiers are redacted unless `IncludePlayerIds = true`: a context field named
`UserId`, `RecipientId`, `BuyerId`, `Player` or anything ending in `UserId` or `PlayerId`,
whatever its value and at any depth, plus `UserId=...`, `Player=...`,
profile keys with the player prefix and `Player` instances in a log context all become
`[player]`. Webhook URLs are always redacted. Context tables are trimmed to twelve keys and two
levels, functions, threads and other Roblox objects are dropped, and every text is cut on a
UTF-8 boundary inside Discord's limits.
Strings over 4096 bytes become `[oversized text omitted]` before redaction, keeping
processing bounded without exposing a partial secret.

## Delivery

Delivery is best effort and bounded. Reports queue per webhook (`Limits.PerDestination`, 64) and
overall (`Limits.MaxQueued`, 200; `Limits.MaxQueuedBytes`, 256 KB). When a queue is full the
oldest expired item goes first, then the lowest-priority item no higher than the newcomer:
a summary gives way to an issue, and an issue is never dropped for a summary. A report older
than `Limits.MaxAge` (15 minutes) is dropped rather than delivered stale.

Discord's `429` and `X-RateLimit-Remaining: 0` are honoured per webhook. A `5xx` or network
error retries with exponential backoff up to `Limits.MaxAttempts` (5); a `401`, `403`, `404`
or `410` marks the webhook dead and drops its queue; a `400`, `413` or `422` is a local defect,
dropped once and never retried. One failing webhook does not hold up another. A timed-out
request is counted as `Uncertain`: it may or may not have landed.

## Types

The add-on is `--!strict` and exports `Options`, `Handle`, `Stats` and `ScribeModule`, so
under the new type solver a misspelt option, a wrong value type, an unknown mention kind or a
misread stat is a diagnostic in the editor rather than a startup error:

```lua
local ScribeTelemetry = require(ServerStorage.ScribeTelemetry)
local telemetry: ScribeTelemetry.Handle = ScribeTelemetry.Start(Scribe, options)
```

## Lifecycle

```lua
local telemetry = ScribeTelemetry.Start(Scribe, options)
telemetry:Test("Alerts")   -- one test message to a named destination: (ok, reason)
telemetry:Preview("Alerts", "All")  -- every report design, synthetic, to one destination: (ok, reason)
telemetry:Flush(5)         -- wait up to 5 s for the queues to drain: drained?
telemetry:GetStats()       -- queue, delivery and per-destination state, no URLs
telemetry:Stop()           -- stop monitoring and remove listeners; idempotent
```

`Start` errors, before anything listens, on a URL that is not http or https, a route to
an unknown destination, an empty route list, a role id that is not digits, or a rule with no
threshold. It refuses a second start for the same Scribe module until the first stops.

In Studio the add-on starts in the `DisabledInStudio` state and sends nothing, unless
`AllowStudio = true`. Set `Environment` (`"production"` by default) to tell servers apart in
the footer.

## Previewing every design

`Preview` sends synthetic examples of the add-on's reports to one destination, so you can see every design in a channel without waiting for an incident:

```lua
telemetry:Preview("Alerts")            -- every scenario
telemetry:Preview("Alerts", "Health")  -- one group
telemetry:Preview("Alerts", "Outage")  -- one scenario
```

The examples come from the same builders, formatting and delivery queue as real reports, so rate limiting and the `Limits` you configured apply. Every title starts with `PREVIEW:` and every embed ends with a field saying the data is synthetic. No role is ever mentioned, and nothing the add-on believes about the server changes: summary baselines, performance streaks, groups and mention cooldowns are untouched, and previews are counted in `GetStats().Previews` rather than `Reports`.

| Kind | Scenarios |
| --- | --- |
| `Health` | `HealthyStartup`, `Degraded`, `Outage`, `PartialRecovery`, `Recovery`, `IncidentUnderway` |
| `Leaderboards` | `LeaderboardDegraded`, `LeaderboardRecovery` |
| `Issues` | `Error`, `Fatal`, `ReceiptCapacity` |
| `Warnings` | `Warning`, `SlowLoad`, `SlowLeavingHook`, `ReceiptRoutingRetry` |
| `Grouping` | `Repeat`, `UpstreamSuppressed` |
| `Performance` | `SlowSaves`, `SaveFailures`, `Traffic`, each with a `Cleared` counterpart |
| `Summaries` | `Summary`, `SummaryNoSamples`, `SummaryNoBudget` |
| `Formatting` | `LongMessage`, `RedactedContext` |

`Preview` returns `(true)` when everything was queued, or `(false, reason)` for an unknown kind or destination, a disabled or dead destination, a full queue, or an add-on that is stopped or disabled in Studio. To preview from a Studio play-test, start the add-on with `AllowStudio = true`.

From the Scribe Studio plugin, the Diagnostics tab's Simulations section has the same preview with a webhook and a kind to choose, behind the plugin's write toggle. The row is always there; its button is enabled only while a started add-on reports `Running` and writes are on, and its tooltip says what is missing otherwise. The add-on registers itself with `Scribe.RegisterAddon` when it starts, even when Studio has disabled it; in Studio, start it with `AllowStudio = true`.

## Not verified live

These were exercised headless against a fake webhook and virtual time, which is what the specs
in `test/Specs/addons/Telemetry*.spec.luau` cover. Three things need a published place and a real
Discord channel, and have not been run:

- delivery from a live server through `HttpService`, including Discord's actual rate-limit
  headers;
- separate-channel routing against three real webhooks;
- how Discord renders the author icon and avatar from Scribe's logo URL.

Run `telemetry:Test("Alerts")` from a server after publishing and check the channel.
