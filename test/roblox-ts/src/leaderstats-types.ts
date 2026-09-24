import Scribe from "@rbxts/scribe";
import ScribeLeaderstats from "@rbxts/scribe-leaderstats";

const bundle = Scribe({
    Template: {
        Coins: 0,
        Progress: { Level: 1 },
        Nickname: Scribe.Optional(""),
        MaybeProfile: Scribe.Optional({ Rank: 1 }),
        Huge: Scribe.Big("1e50"),
        Items: Scribe.ArrayOf({ Value: 1 }),
        Flags: Scribe.Flags(["VIP", "Tester"]),
        Dictionary: Scribe.DictOf({ Value: 1 }),
        Map: Scribe.MapOf("integer", { Value: 1 }),
        Set: Scribe.SetOf(""),
        Position: Scribe.Vector3(new Vector3()),
        "Dot.Name": 1,
        Nested: { "": 1 },
    },
    ProfileStoreIndex: "LeaderstatsTypes",
    ProfileKeyPrefix: "PLAYER_",
});

ScribeLeaderstats.Start(bundle.Server, { Coins: "Coins", Level: "Progress.Level" });
// @ts-expect-error Stat paths are inferred from this server's schema.
ScribeLeaderstats.Start(bundle.Server, { Coins: "Coinz" });
// @ts-expect-error Records cannot be displayed as scalar values.
ScribeLeaderstats.Start(bundle.Server, { Progress: "Progress" });
// @ts-expect-error Optional values need an always-present scalar field for display.
ScribeLeaderstats.Start(bundle.Server, { Nickname: "Nickname" });
// @ts-expect-error An optional ancestor is also excluded.
ScribeLeaderstats.Start(bundle.Server, { Rank: "MaybeProfile.Rank" });
// @ts-expect-error Big values require an explicitly formatted string field.
ScribeLeaderstats.Start(bundle.Server, { Huge: "Huge" });
// @ts-expect-error Array elements are not static paths.
ScribeLeaderstats.Start(bundle.Server, { Item: "Items.1.Value" });
// @ts-expect-error Flags are containers rather than booleans.
ScribeLeaderstats.Start(bundle.Server, { VIP: "Flags" });
// @ts-expect-error This addon only accepts the server API.
ScribeLeaderstats.Start(bundle.Client, { Coins: "Coins" });
// @ts-expect-error Configuration values are stat paths, not direct values.
ScribeLeaderstats.Start(bundle.Server, { Coins: 3 });
// @ts-expect-error Dynamic dictionary entries are not always-present static paths.
ScribeLeaderstats.Start(bundle.Server, { Item: "Dictionary.sword.Value" });
// @ts-expect-error Numeric map entries are not static paths.
ScribeLeaderstats.Start(bundle.Server, { Item: "Map.10.Value" });
// @ts-expect-error Sets are containers.
ScribeLeaderstats.Start(bundle.Server, { Set: "Set" });
// @ts-expect-error Roblox datatype properties are not Scribe scalar descendants.
ScribeLeaderstats.Start(bundle.Server, { X: "Position.X" });
// @ts-expect-error Dots in actual field names cannot be represented in a dot-separated path.
ScribeLeaderstats.Start(bundle.Server, { Dotted: "Dot.Name" });
// @ts-expect-error Empty path segments are refused by the runtime.
ScribeLeaderstats.Start(bundle.Server, { Empty: "Nested." });
