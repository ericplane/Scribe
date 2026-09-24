import type Scribe from "@rbxts/scribe";
import type Leaderstats from "@rbxts/scribe-leaderstats";

interface Harness<T> {
    readonly Join: (this: void, id: number) => LuaTuple<[Player, unknown, Scribe.PlayerData<T>]>;
    readonly Data: Scribe.ServerData<T>;
    readonly Cleanup: (this: void) => void;
}

/** Executed with real Scribe accessors and the Luau addon's injected instance tree. */
function verify(
    scribe: typeof Scribe,
    leaderstats: typeof Leaderstats,
    make: <T>(options: { Template: T }) => Harness<T>,
    makeDependencies: (this: void, player: Player) => Leaderstats.Dependencies,
) {
    const template = { Coins: scribe.Number(1.25), Progress: { Get: 4 }, Title: "Novice", Winner: false };
    const harness = make({ Template: template });
    const [player, , data] = harness.Join(98911);
    const dependencies = makeDependencies(player);
    const handle = leaderstats.Start(harness.Data, {
        Coins: "Coins", Collision: "Progress.Get", Title: "Title", Winner: "Winner",
    }, dependencies);
    task.wait();
    const folder = player.FindFirstChild("leaderstats");
    assert(folder !== undefined && folder.IsA("Folder"), "leaderstats folder created");
    const coins = folder.FindFirstChild("Coins");
    const collision = folder.FindFirstChild("Collision");
    const title = folder.FindFirstChild("Title");
    const winner = folder.FindFirstChild("Winner");
    assert(coins !== undefined && coins.IsA("NumberValue"));
    assert(collision !== undefined && collision.IsA("NumberValue"));
    assert(title !== undefined && title.IsA("StringValue"));
    assert(winner !== undefined && winner.IsA("BoolValue"));
    const readCoins = () => coins.Value;
    assert(readCoins() === 1.25 && collision.Value === 4, "numeric values and method-name paths");
    data.Coins.Set(4.75);
    data.Title.Set("Winner");
    data.Winner.Set(true);
    task.wait();
    assert(readCoins() === 4.75 && title.Value === "Winner" && winner.Value, "changes propagate to player list");
    coins.Value = 999;
    assert(data.Coins.Get() === 4.75, "leaderstats never writes back into Scribe");
    handle.Stop();
    handle.Stop();
    assert(player.FindFirstChild("leaderstats") === undefined, "Stop colon-call ABI and cleanup");
    data.Coins.Set(7);
    task.wait();
    assert(player.FindFirstChild("leaderstats") === undefined, "stopped observers cannot recreate a display");
    harness.Cleanup();
}

export = verify;
