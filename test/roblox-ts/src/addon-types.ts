import Scribe from "@rbxts/scribe";
import React from "@rbxts/react";
import Vide from "@rbxts/vide";
import Fusion from "@rbxts/fusion";
import ScribeReact from "@rbxts/scribe-react";
import ScribeVide from "@rbxts/scribe-vide";
import ScribeFusion from "@rbxts/scribe-fusion";
import ScribeTelemetry from "@rbxts/scribe-telemetry";

declare const numberNode: Scribe.ReadableNode<number>;
declare const textNode: Scribe.ReadableNode<string>;
const react = ScribeReact(React);
const useVide = ScribeVide(Vide);
const useFusion = ScribeFusion(Fusion);
const [videNumber] = useVide(numberNode);
const [fusionNumber] = useFusion(numberNode);

// @ts-expect-error React preserves the accessor value instead of returning any.
const wrongReactValue: string = react.useScribe(numberNode);
// @ts-expect-error Binding.map sees the actual accessor value.
react.useScribeBinding(textNode).map((value: number) => value + 1);
// @ts-expect-error Vide sources retain their input value type.
videNumber("wrong");
// @ts-expect-error Fusion Values retain their input value type.
fusionNumber.set("wrong");
// @ts-expect-error The factory requires the framework operations it uses.
ScribeReact({});

const telemetry = ScribeTelemetry.Start(Scribe, {
    Webhooks: { Alerts: { Url: "https://example.invalid/webhook" } },
    Default: "Alerts",
    Routes: { Health: ["Alerts"], Summaries: false },
});
// @ts-expect-error Handles know their configured destination names.
telemetry.Test("Alert");
// @ts-expect-error Preview kinds are an exhaustive public union.
telemetry.Preview("Alerts", "NotAReport");
// @ts-expect-error Disabled-in-Studio handles can have no destination stats.
telemetry.GetStats().Destinations.Alerts.Delivered;
ScribeTelemetry.Start(Scribe, {
    Webhooks: { Alerts: { Url: "https://example.invalid/webhook" } },
    // @ts-expect-error Route names cannot introduce undeclared destinations.
    Routes: { Issues: "Alert" },
});
ScribeTelemetry.Start(Scribe, {
    Webhooks: { Alerts: { Url: "https://example.invalid/webhook" } },
    Performance: {
        Rules: {
            // @ts-expect-error Runtime rules require a positive Threshold value.
            SlowSaves: { Enabled: true },
        },
    },
});

declare const fusion03: ScribeFusion.ScopedFramework<unknown[]>;
const scoped = ScribeFusion(fusion03, []);
const [scopedNumber] = scoped(numberNode);
// @ts-expect-error Scoped Fusion has the same precise setter type.
scopedNumber.set("wrong");
// @ts-expect-error Fusion 0.3 has no legacy get method.
scopedNumber.get();

ScribeTelemetry.Start(Scribe, {
    Webhooks: { Alerts: { Url: "https://example.invalid/webhook" } },
    // @ts-expect-error Leaderboard routes obey the same configured destination names.
    Routes: { Leaderboards: "UnknownDestination" },
});
ScribeTelemetry.Start(Scribe, {
    Webhooks: { Alerts: { Url: "https://example.invalid/webhook" } },
    // @ts-expect-error Poll intervals are numeric seconds.
    Leaderboards: { Interval: "15 seconds" },
});
// @ts-expect-error A snapshot might not yet have been observed.
const snapshotAge: number = telemetry.GetStats().Leaderboards.SnapshotAge;
// @ts-expect-error Monitor availability is separate from an individual board's health.
const boardHealth: "Healthy" | "Degraded" = telemetry.GetStats().Leaderboards.State;
