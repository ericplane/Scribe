import Scribe from "@rbxts/scribe";
import ScribeLeaderstats from "@rbxts/scribe-leaderstats";

const bundle = Scribe({
    Template: {
        Coins: Scribe.Number(0),
        Progress: { Level: Scribe.Int(1), Get: 4 },
        Title: "Newcomer",
        Winner: false,
        Secret: Scribe.ServerOnly({ Wins: 0 }),
        Round: Scribe.Session({ Score: 0 }),
    },
    ProfileStoreIndex: "LeaderstatsFixture",
    ProfileKeyPrefix: "PLAYER_",
    Mode: "Mock",
});

export function createLeaderstats() {
    const handle = ScribeLeaderstats.Start(bundle.Server, {
        Coins: "Coins",
        Level: "Progress.Level",
        Title: "Title",
        Winner: "Winner",
        // Selecting a private path explicitly publishes it to the player list.
        Wins: "Secret.Wins",
        Score: "Round.Score",
        Collision: "Progress.Get",
    });
    handle.Stop();
    return handle;
}

// Only the runtime-required API slice is necessary; schema inference follows WaitForData.
export function createFromPublicSlice() {
    return ScribeLeaderstats.Start({
        WaitForData: bundle.Server.WaitForData,
        SessionEnded: bundle.Server.SessionEnded,
    }, { Level: "Progress.Level" });
}
