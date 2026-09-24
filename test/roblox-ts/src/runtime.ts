import type Scribe from "@rbxts/scribe";

interface Harness<T, S = {}> {
    readonly Join: (this: void, id: number) => LuaTuple<[Player, unknown, Scribe.PlayerData<T>]>;
    readonly Data: Scribe.ServerData<T, S>;
    readonly Cleanup: (this: void) => void;
}

/** This emitted Luau is executed against the same Scribe harness as the Luau suite. */
function verify(scribe: typeof Scribe, make: <T, S = {}>(options: { Template: T; Options?: { ServerStore: S } }) => Harness<T, S>) {
    const template = {
        Coins: scribe.Int(5),
        Title: scribe.Enum("Novice", ["Novice", "Veteran"]),
        Enabled: true,
        Bag: scribe.ArrayOf({ Quantity: 0 }),
        Inventory: scribe.DictOf({ Quantity: 0 }),
        Slots: scribe.MapOf("integer", { Quantity: 0 }),
        Tags: scribe.SetOf(""),
        Perks: scribe.Flags(["VIP", "Boost"]),
        Boost: scribe.Timed(false),
        Big: scribe.Big("1e30"),
        Get: 17,
    };
    const harness = make({ Template: template, Options: { ServerStore: { Wave: 1, Child: 2, Changed: "Lobby" } } });
    const [player, , data] = harness.Join(98910);
    const [ready, reason] = harness.Data.WaitForData(player);
    assert(ready === data && reason === undefined, "multiple return ABI");
    assert(harness.Data.ServerStore.Wave.Increment(2) === 3, "typed server store accessor");
    assert(harness.Data.ServerStore.Child.Get() === 2, "server store root collision");
    harness.Data.ServerStore.Changed.Set("Arena");
    assert(harness.Data.ServerStore.Changed() === "Arena", "server store roots are plain named accessors");
    assert(data.Coins.Increment(3) === 8, "dot calls must not inject self");
    let observed = 0;
    const disconnect = data.Coins.Changed(value => { observed = value; });
    data.Coins.Set(11);
    assert(observed === 11, "typed observer callback");
    disconnect();
    assert(data.Coins() === 11 && data().Coins === 11, "callable accessor reads");
    assert(data.Coins(10) === 10, "callable accessor write");
    assert(data.Coins(value => value + 1) === 11, "callable accessor update");
    data.Bag.Insert({ Quantity: 4 });
    assert(data.Bag.Child(1).Quantity.Get() === 4, "Child is one-based");
    assert(data.Bag[1].Quantity.Get() === 4, "proxy brackets preserve raw indices");
    assert(data.Bag.Get()[0].Quantity === 4, "snapshot arrays use TS indices");
    const [removed, position] = data.Bag.RemoveValue({ Quantity: 4 });
    assert(removed !== undefined && removed.Quantity === 4 && position === 1, "RemoveValue LuaTuple");
    assert(data.Inventory.Child("missing").Quantity.Get() === undefined, "absent dynamic descendants");
    data.Inventory.Child("Get").Quantity.Increment(9);
    assert(data.Inventory.Child("Get").Quantity.Get() === 9, "method-name dictionary key");
    assert(data.Child("Get").Get() === 17, "method-name static key");
    data.Slots.Child(42).Quantity.Set(7);
    const slot = data.Slots.Get().get(42);
    assert(slot !== undefined && slot.Quantity === 7, "sparse numeric map has no index shift");
    assert(data.Tags.Add("sword") && data.Tags.Has("sword"), "set methods");
    data.Perks.Enable("VIP");
    assert(data.Perks.Has("VIP"), "flags");
    data.Boost.SetTimed(true, 100);
    const [active, remaining] = data.Boost.Active();
    assert(active && remaining !== undefined && remaining > 0, "timed multi-return");
    const big = data.Big.Get();
    assert(big.Multiply(2).Divide(2).Equals(big), "Big self methods");
    assert(big.Add(big).Compare(big) > 0, "Big arithmetic");
    assert(big.Negate().Negate().Equals(big), "Big negation");
    const [committed] = harness.Data.Transaction(player, () => { data.Coins.Increment(1); });
    assert(committed && data.Coins.Get() === 12, "transaction callback convention");
    harness.Cleanup();

    // Exercise both construction forms and the real client-side mock/request boundary.
    type Commands = { Echo: (value: number) => LuaTuple<[number]> };
    const bundle = scribe< { Coins: number }, {}, Commands>({
        Template: { Coins: 0 }, IsRunning: false, Mode: "Mock", Banner: false,
        ProfileStoreIndex: "RbxtsInterop", ProfileKeyPrefix: "RT_",
        Leaderboards: { TopCoins: { Stat: "Coins", WriteInterval: 45 } },
    });
    bundle.Client.Mock({ Coins: 7 });
    assert(bundle.Client.Coins.Get() === 7, "callable Scribe constructor");
    assert(bundle.Client.Coins() === 7, "client field callable accessor");
    bundle.Client.MockCommand("Echo", value => $tuple(value + 1));
    const [echo] = bundle.Client.Request("Echo", 6);
    assert(echo === 7, "request multi-return contract");
    const [prompted, promptReason, promptFailure] = bundle.Client.PromptPurchase("Gold");
    assert(!prompted && promptReason === "edit-mode" && promptFailure === scribe.RequestFailed, "client prompt dot call and failure tuple");
    bundle.Client.Stop();
    const second = scribe.new({
        Template: { Coins: 0, Boost: scribe.Timed(true) }, IsRunning: false, Mode: "Mock", Banner: false,
        ServerStore: { Wave: 1, Get: 2, Private: scribe.ServerOnly(9) },
        ProfileStoreIndex: "RbxtsInteropNew", ProfileKeyPrefix: "RN_",
    });
    assert(second.Client.Coins.Get() === 0, "Scribe.new dot convention");
    assert(second.Client.ServerStore.Wave() === 1, "client receives server store template");
    assert(second.Client.ServerStore.Get.Get() === 2, "client store preserves reserved names");
    const [clientActive, clientRemaining] = second.Client.Boost.Active();
    assert(!clientActive && clientRemaining === undefined, "client timer checks deadlines, not value truthiness");
    second.Client.Stop();

    const disconnectLog = scribe.AddLogSink(() => {}, { Level: "Error", MaxQueued: 8 });
    disconnectLog();
    assert(typeIs(scribe.GetLeaderboardSnapshot(), "table"), "leaderboard snapshot dot call");
}
export = verify;
