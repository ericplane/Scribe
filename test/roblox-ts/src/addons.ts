import Scribe from "@rbxts/scribe";
import React from "@rbxts/react";
import Vide from "@rbxts/vide";
import Fusion from "@rbxts/fusion";
import ScribeReact from "@rbxts/scribe-react";
import ScribeVide from "@rbxts/scribe-vide";
import ScribeFusion from "@rbxts/scribe-fusion";
import ScribeTelemetry from "@rbxts/scribe-telemetry";

const reactAdapter = ScribeReact(React);
const useVide = ScribeVide(Vide);
const useFusion = ScribeFusion(Fusion);

// Native framework consumers verify that the bridge preserves real framework types.
export function CoinLabel(props: { accessor: Scribe.ReadableNode<number> }) {
    const coins: number = reactAdapter.useScribe(props.accessor);
    const binding: React.Binding<number> = reactAdapter.useScribeBinding(props.accessor);
    return React.createElement("TextLabel", {
        Text: binding.map((value) => `${value} coins`),
        LayoutOrder: coins,
    });
}

export function videScope(accessor: Scribe.ReadableNode<number>) {
    return Vide.root(() => {
        const [coins, disconnect] = useVide(accessor);
        const nativeSource: Vide.Source<number> = coins;
        const value: number = nativeSource();
        Vide.cleanup(disconnect);
        return value;
    });
}

export function fusionValue(accessor: Scribe.ReadableNode<number>) {
    const [coins, disconnect] = useFusion(accessor);
    const nativeValue: Fusion.Value<number> = coins;
    const current: number = nativeValue.get();
    disconnect();
    return current;
}

// A separately supplied Fusion 0.3 typing retains its extra members and value type.
interface ScopedFramework {
    readonly Value: <T>(this: void, scope: unknown[], value: T) => ScribeFusion.ScopedValue<T> & {
        readonly additionalGraphMember: "preserved";
    };
}
export function scopedFusionValue(fusion: ScopedFramework, scope: unknown[], accessor: Scribe.ReadableNode<number>) {
    const useScoped = ScribeFusion(fusion, scope);
    const [coins, disconnect] = useScoped(accessor);
    const member: "preserved" = coins.additionalGraphMember;
    coins.set(3);
    disconnect();
    return member;
}

// The fixture cannot send reports: Studio mode explicitly disables the handle.
export function telemetryHandle() {
    const handle = ScribeTelemetry.Start(Scribe, {
        Webhooks: { Alerts: { Url: "https://example.invalid/webhook" } },
        Default: "Alerts",
        Routes: { Health: "Alerts", Leaderboards: ["Alerts"], Summaries: false },
        Leaderboards: { Enabled: true, Interval: 15, MaxBoards: 12 },
        Performance: { Rules: { SlowSaves: { Threshold: 5 } } },
        Studio: true,
        AllowStudio: false,
    });
    const [queued, reason] = handle.Test("Alerts");
    const [previewed] = handle.Preview("Alerts", "SlowSaves");
    handle.Preview("Alerts", "Leaderboards");
    handle.Preview("Alerts", "LeaderboardDegraded");
    handle.Preview("Alerts", "LeaderboardRecovery");
    handle.Preview("Alerts", "SlowLoad");
    handle.Preview("Alerts", "SlowLeavingHook");
    handle.Preview("Alerts", "ReceiptCapacity");
    handle.Preview("Alerts", "ReceiptRoutingRetry");
    const count: number = handle.GetStats().Reports;
    const boards: ScribeTelemetry.LeaderboardStats = handle.GetStats().Leaderboards;
    const boardState: ScribeTelemetry.LeaderboardMonitorState = boards.State;
    const snapshotAge: number | undefined = boards.SnapshotAge;
    const omitted: number = boards.Omitted;
    assert(boardState === "DisabledInStudio" && snapshotAge === undefined && omitted === 0);
    handle.Flush(1);
    handle.Stop();
    return $tuple(queued, previewed, reason, count);
}
