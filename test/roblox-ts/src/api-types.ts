import Scribe from "@rbxts/scribe";

const apiTemplate = {
    Coins: Scribe.Int(0),
    Settings: { Music: true },
    PublicTitle: Scribe.Shared(Scribe.String("Guest")),
    Secret: Scribe.ServerOnly(Scribe.Int(0)),
};
const apiStore = { Wave: Scribe.Int(1), Match: { InProgress: false } };
interface Commands {
    Buy: (this: void, item: string, quantity: number) => LuaTuple<[boolean, string | undefined]>;
    Ping: (this: void) => LuaTuple<[number]>;
}

export function checkAPI(player: Player): void {
    const invalidBoard: Scribe.LeaderboardConfig<typeof apiTemplate> = {
        Stat: "Coins",
        // @ts-expect-error WriteInterval is a number of seconds.
        WriteInterval: "thirty",
    };
    print(invalidBoard);
    const bundle = Scribe<typeof apiTemplate, typeof apiStore, Commands>({
        Template: apiTemplate,
        ServerStore: apiStore,
        ProfileStoreIndex: "ApiTypes",
        ProfileKeyPrefix: "P_",
        Mode: "Mock",
        Leaderboards: { Richest: { Stat: "Coins", Period: "Weekly", WriteInterval: 30 } },
        Products: { Gold: { Id: 1, PaidRandom: false, Grant: data => { data.Coins.Increment(1); } } },
        RetiredProducts: { OldGold: { Id: 2, Grant: data => { data.Coins.Increment(1); } } },
        MaxReceiptHistoryBytes: 1048576,
        LogRingLevel: "Debug",
        OnPlayerLeaving: (_player, data, reason) => {
            data.Coins.Increment(1);
            const lifecycle: Scribe.LifecycleReason = reason;
            print(lifecycle);
        },
    });
    const server = bundle.Server;
    const client = bundle.Client;
    server.Command("Buy", { Args: ["string", "number"], Idempotent: true }, (_player, item, quantity) => {
        const id: string = item;
        const count: number = quantity;
        print(id, count);
        return $tuple(true, undefined);
    });
    server.Command("Ping", _player => $tuple(1));
    client.MockCommand("Buy", (_item, _quantity) => $tuple(true, undefined));
    const [ok, reason, frameworkFailure] = client.RequestOnce("Buy", "purchase-1", "Sword", 1);
    const success: boolean = ok;
    const message: string | undefined = reason;
    if (frameworkFailure === Scribe.RequestFailed) print("Framework refused the request", message);
    const [numberOrFalse] = client.Request("Ping");
    const score: number | false = numberOrFalse;
    print(success, message, score);
    const [prompted, promptReason, promptFailure] = client.PromptPurchase("Gold");
    const promptAccepted: boolean = prompted;
    const promptMessage: string | undefined = promptReason;
    const promptMarker: Scribe.RequestFailedMarker | undefined = promptFailure;
    if (promptFailure === Scribe.RequestFailed) print("Prompt request failed", promptMessage);
    const [serverPrompted, serverPromptReason] = server.PromptPurchase(player, "Gold");
    print(promptAccepted, promptMarker, serverPrompted, serverPromptReason);

    const [state, phase] = server.GetState(player);
    const session: Scribe.SessionState = state;
    const loading: Scribe.LoadPhase | undefined = phase;
    if (loading === Scribe.LoadPhase.AcquiringSession) print("Waiting for the previous server");
    const [data, waitReason] = server.WaitForData(player);
    if (data !== undefined) data.Coins.Increment(1);
    print(session, loading, waitReason);
    server.ServerStore.Wave.Set(2);
    const wave: number = client.ServerStore.Wave.Get();
    client.ServerStore.Match.InProgress.Observe(active => print(active));
    print(wave);
    const shared = client.GetShared(player);
    if (shared !== undefined) {
        const title: string = shared.PublicTitle;
        print(title);
        // @ts-expect-error Only Shared roots appear in another player's snapshot.
        print(shared.Coins);
    }

    server.OnSave.Connect(event => {
        const elapsed: number | undefined = event.Duration;
        print(event.Player, event.Ok, elapsed);
    });
    server.SessionEnded.Once((_player, lifecycle) => print(lifecycle));
    client.OnOwnershipChanged.Connect((key, owned) => print(key, owned));
    const ownershipConnection = server.OnOwnershipChanged.Connect((_player, key, owned) => print(key, owned));
    ownershipConnection.Disconnect();
    server.GetPurchases(player, { Kind: "InGame" });
    server.Purchase(player, { Cost: { Path: "Coins", Amount: 10 }, ItemId: "Sword", IdempotencyKey: "purchase-1", PaidRandom: false });
    const [updated, updateReason, violations] = server.UpdateOffline(1, raw => { raw["Coins"] = 2; }, { Validate: true });
    print(updated, updateReason, violations);
    client.Mock({ Settings: { Music: false } }, { Perks: ["VIP"] });
    const [verdict] = server.Exchange.Attempt(player, [{ Path: ["Coins"], Kind: "Qty", Amount: 1 }], player, []);
    const result: "Committed" | "Aborted" | undefined = verdict;
    print(result);
    const health = server.GetLeaderboardStatus("Richest");
    if (health !== undefined) {
        const status: Scribe.LeaderboardStatus = health.Status;
        const age: number | undefined = health.ReadAge;
        print(status, age, health.PendingWrites, health.RetryingWrites, health.RejectedWrites);
        // @ts-expect-error A board can be unrefreshed, so ReadAge is optional.
        const definiteAge: number = health.ReadAge;
        print(definiteAge);
    }
    const snapshot: Scribe.LeaderboardSnapshotEntry[] = Scribe.GetLeaderboardSnapshot();
    for (const board of snapshot) {
        const state: Scribe.LeaderboardStatusInfo = board;
        print(board.BundleId, board.Name, state.Status, state.LastWriteError);
    }
    const removeSink = Scribe.AddLogSink(entry => {
        const code: Scribe.LogCode = entry.Code;
        if (code === "RECEIPT_HISTORY_FULL" || code === "PLAYER_LEAVING_HOOK_SLOW") print(entry.Message);
    }, { Level: "Warn", MaxQueued: 32 });
    removeSink();
    const retired: Scribe.GiftReason = Scribe.GiftReason.ProductRetired;
    print(retired);

    // @ts-expect-error Command argument tuple comes from the shared contract.
    client.Request("Buy", 4, "Sword");
    // @ts-expect-error Unknown command names are rejected for a supplied contract.
    client.Request("Missing");
    // @ts-expect-error RequestOnce requires the idempotency key before the arguments.
    client.RequestOnce("Buy", "Sword", 1);
    // @ts-expect-error Command result must match the shared contract.
    server.Command("Ping", _player => $tuple("wrong"));
    // @ts-expect-error A client prompt always targets the local player.
    client.PromptPurchase(player, "Gold");
    // @ts-expect-error Prompt by registered name, not an asset ID.
    client.PromptPurchase(1);
    // @ts-expect-error The framework-failure marker is not prose or any.
    const promptFailureText: string | undefined = promptFailure;
    // @ts-expect-error A server prompt still requires its target player.
    server.PromptPurchase("Gold");
    // @ts-expect-error Server-owned client mirrors cannot be written.
    client.ServerStore.Wave.Set(2);
    // @ts-expect-error Readonly server-owned state applies at nested depths too.
    client.ServerStore.Match.InProgress.Toggle();
    // @ts-expect-error Purchase cost must name a numeric field.
    server.Purchase(player, { Cost: { Path: "Settings.Music", Amount: 1 }, ItemId: "Sword" });
    // @ts-expect-error Arbitrary stored values require narrowing before use.
    const rawCoins: number = server.GetOffline(1)?.Coins;
    // @ts-expect-error Mutation method is not present on a saved result object.
    server.GetSaveInfo(player).Set(true);
    // @ts-expect-error Leaderboard health is a server diagnostic, not a client service.
    client.GetLeaderboardStatus("Richest");
    // @ts-expect-error Board health has its own states, without service-wide Outage.
    const invalidHealth: Scribe.LeaderboardStatus = "Outage";
    // @ts-expect-error LoadPhase is a phase union, not a session-state alias.
    const invalidPhase: Scribe.LoadPhase = "Ready";
    // @ts-expect-error Sink capacity is a number of queued entries.
    Scribe.AddLogSink(entry => print(entry), { MaxQueued: "32" });
    // @ts-expect-error A quantity leg must declare how much is exchanged.
    server.Exchange.Attempt(player, [{ Path: ["Coins"], Kind: "Qty" }], player, []);
    // @ts-expect-error Settle takes an explicit verdict, not an outcome string.
    server.Exchange.Settle("exchange", "Committed");
    print(invalidHealth, invalidPhase);
    print(rawCoins, promptFailureText);
}

/** An independently annotated shared template preserves server-store inference. */
export function checkServerTemplate(player: Player): void {
    interface ServerTemplate {
        Wave: number;
        Status: string;
        Round: { Active: boolean };
        PrivateWave: Scribe.ServerOnly<number>;
    }
    const serverTemplate: ServerTemplate = {
        Wave: 0,
        Status: "Lobby",
        Round: { Active: false },
        PrivateWave: Scribe.ServerOnly(0),
    };
    const bundle = Scribe({
        Template: apiTemplate,
        ServerStore: serverTemplate,
        ProfileStoreIndex: "ServerTemplate",
        ProfileKeyPrefix: "P_",
    });
    const store: Scribe.ServerStore<ServerTemplate> = bundle.Server.ServerStore;
    store.Wave.Increment(1);
    store.PrivateWave.Set(1);
    const wave: number = bundle.Client.ServerStore.Wave.Get();
    const status: string = bundle.Client.ServerStore.Status.Get();
    bundle.Client.ServerStore.Round.Child("Active").Observe(active => print(active));
    bundle.Server.Get(player).Coins.Increment(1);
    print(wave, status);
    // @ts-expect-error The annotated store preserves each field's value type.
    store.Wave.Set("one");
    // @ts-expect-error Nested server-store writes are unavailable in the client mirror.
    bundle.Client.ServerStore.Round.Child("Active").Toggle();
    // @ts-expect-error ServerOnly store roots do not exist on the client.
    bundle.Client.ServerStore.PrivateWave.Get();
    // @ts-expect-error Store roots are separate from the player's persisted template.
    bundle.Server.Get(player).Wave.Get();

    const badOptions: Scribe.ScribeOptions<typeof apiTemplate> = {
        Template: apiTemplate, ProfileStoreIndex: "InvalidOptions", ProfileKeyPrefix: "P_",
        // @ts-expect-error Receipt admission is a byte count, not a text setting.
        MaxReceiptHistoryBytes: "1048576",
        // @ts-expect-error Ring severity uses the same exact log-level vocabulary.
        LogRingLevel: "Verbose",
        RetiredProducts: { OldGold: { Id: 2, Grant: data => {
            // @ts-expect-error Retired-product grants retain the current player-template type.
            data.Coins.Set("one");
        } } },
    };
    print(badOptions);
}

export function checkSeparateTemplateRoots(): void {
    Scribe({
        Template: { Coins: 0 },
        // @ts-expect-error Both templates share root IDs, so root names cannot overlap.
        ServerStore: { Coins: 1 },
        ProfileStoreIndex: "Overlap", ProfileKeyPrefix: "P_",
    });
    Scribe.new({
        Template: { Coins: 0 },
        // @ts-expect-error The named constructor enforces the same root-name constraint.
        ServerStore: { Coins: 1 },
        ProfileStoreIndex: "OverlapNew", ProfileKeyPrefix: "P_",
    });
    const overlappingStore = { Coins: 1 };
    const invalidOptions: Scribe.ScribeOptions<{ Coins: number }, typeof overlappingStore> = {
        Template: { Coins: 0 },
        // @ts-expect-error Annotated options and nonliteral templates are checked too.
        ServerStore: overlappingStore,
        ProfileStoreIndex: "OverlapAnnotated", ProfileKeyPrefix: "P_",
    };
    print(invalidOptions);

    // Repeated nested names under separate roots do not collide.
    const distinct = Scribe.new({
        Template: { Progress: { Level: 1 } },
        ServerStore: { Round: { Level: 2 } },
        ProfileStoreIndex: "Distinct", ProfileKeyPrefix: "P_",
    });
    const level: number = distinct.Server.ServerStore.Round.Level.Increment(1);
    print(level);
    // A dictionary annotation has erased its concrete keys; startup validates those.
    const broadPlayer: { [root: string]: number } = { Coins: 0 };
    const broadStore: { [root: string]: number } = { Wave: 1 };
    Scribe({ Template: broadPlayer, ServerStore: { Wave: 1 }, ProfileStoreIndex: "BroadPlayer", ProfileKeyPrefix: "P_" });
    Scribe.new({ Template: { Coins: 0 }, ServerStore: broadStore, ProfileStoreIndex: "BroadStore", ProfileKeyPrefix: "P_" });
}

export function checkUncontractedCommands(player: Player): void {
    const bundle = Scribe({
        Template: { Coins: 0 },
        ProfileStoreIndex: "UntypedCommands",
        ProfileKeyPrefix: "P_",
        Products: { Gold: { Id: 1, Grant: data => { data.Coins.Increment(1); } } },
        OnPlayerLeaving: (_player, data) => { data.Coins.Increment(1); },
    });
    bundle.Server.Command("TypedHandler", (_player: Player, amount: number) => $tuple(amount));
    const [unknownResult] = bundle.Client.Request("TypedHandler", 1);
    // @ts-expect-error Uncontracted requests cannot silently turn results into any.
    const amount: number = unknownResult;
    print(player, amount);
}
