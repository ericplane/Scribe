import Scribe from "@rbxts/scribe";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
type Assert<T extends true> = T;
type IsAny<T> = 0 extends (1 & T) ? true : false;

const schemaTemplate = {
    Coins: Scribe.Int(0, { Min: 0 }),
    Enabled: true,
    Title: Scribe.Enum("Guest", ["Guest", "Member"]),
    Note: Scribe.Optional(Scribe.String("")),
    Timed: Scribe.Timed(false),
    Wealth: Scribe.Big("1e100"),
    Flags: Scribe.Flags(["Move", "Combat"]),
    Unlocks: Scribe.SetOf(Scribe.Enum("Red", ["Red", "Blue"])),
    Settings: { Music: true, Volume: Scribe.Number(1), Note: Scribe.Optional(Scribe.String("")) },
    Collision: { Get: Scribe.Int(1), Child: Scribe.String(""), Plain: false },
    Players: Scribe.ArrayOf({
        Name: Scribe.String(""),
        Level: Scribe.Int(1),
        Note: Scribe.Optional(Scribe.String("")),
        Detail: { Wins: Scribe.Int(0), Label: Scribe.String("") },
        Raw: [] as { Name: string; Quantity: number }[],
        Hidden: Scribe.ServerOnly(Scribe.Int(0)),
    }),
    Items: Scribe.DictOf({ Quantity: Scribe.Int(1), Note: Scribe.Optional(Scribe.String("")) }),
    IntegerMap: Scribe.MapOf("integer", Scribe.String("")),
    StringMap: Scribe.MapOf("string", { Score: Scribe.Int(0), Label: Scribe.String("") }),
    PlainArray: [] as { Name: string; Quantity: number }[],
    Secret: Scribe.ServerOnly({ Quantity: Scribe.Int(0) }),
    Public: Scribe.Shared({ Title: Scribe.String(""), Hidden: Scribe.ServerOnly(false) }),
    Session: Scribe.Session({ InCombat: false }),
    Doubled: Scribe.Derived(Scribe.Int(0), ["Coins"], (coins: number) => coins * 2),
    Position: Scribe.Vector3(Vector3.zero),
    Pose: Scribe.CFrame(CFrame.identity),
    Blob: buffer.create(4),
};
type Schema = typeof schemaTemplate;
type Data = Scribe.PlayerData<Schema>;
type Client = Scribe.ClientData<Schema>;
type PlayerSchema = Schema["Players"] extends Scribe.ArrayOf<infer E> ? E : never;
type GetValue<N extends { Get: (this: void) => unknown }> = ReturnType<N["Get"]>;

export type SchemaAssertions = [
    Assert<Equal<GetValue<Data["Coins"]>, number>>,
    Assert<Equal<GetValue<Data["Enabled"]>, boolean>>,
    Assert<Equal<GetValue<Data["Title"]>, "Guest" | "Member">>,
    Assert<Equal<GetValue<Data["Note"]>, string | undefined>>,
    Assert<Equal<GetValue<Data["Timed"]>, boolean>>,
    Assert<Equal<ReturnType<Client["Timed"]["Active"]>, LuaTuple<[boolean, number | undefined]>>>,
    Assert<Equal<GetValue<Data["Wealth"]>, Scribe.BigValue>>,
    Assert<Equal<GetValue<Data["Flags"]>, ReadonlyArray<"Move" | "Combat">>>,
    Assert<Equal<GetValue<Data["Unlocks"]>, ReadonlyArray<"Red" | "Blue">>>,
    Assert<Equal<GetValue<Data["IntegerMap"][number]>, string | undefined>>,
    Assert<Equal<GetValue<Data["Items"][string]["Quantity"]>, number | undefined>>,
    Assert<Equal<GetValue<Data["Players"][number]["Level"]>, number | undefined>>,
    Assert<Equal<GetValue<Data["Position"]>, Vector3>>,
    Assert<Equal<GetValue<Data["Pose"]>, CFrame>>,
    Assert<Equal<GetValue<Data["Blob"]>, buffer>>,
    Assert<Equal<GetValue<Data["Doubled"]>, number>>,
    Assert<Equal<ReturnType<Data["Coins"]["Set"]>, number>>,
    Assert<Equal<ReturnType<Data["Players"]["Remove"]>, Scribe.ValueOf<PlayerSchema> | undefined>>,
    Assert<Equal<ReturnType<Data["Items"][string]["Quantity"]["Default"]>, number>>,
    Assert<Equal<ReturnType<Data["PlainArray"][number]["Name"]["Default"]>, string | undefined>>,
    Assert<Equal<IsAny<GetValue<Data>>, false>>,
    Assert<Equal<IsAny<GetValue<Data["Players"][number]>>, false>>,
    Assert<Equal<IsAny<GetValue<Data["Items"][string]>>, false>>,
    Assert<Equal<IsAny<GetValue<Data["Blob"]>>, false>>,
    Assert<Equal<"Secret" extends keyof Client ? true : false, false>>,
    Assert<Equal<"Hidden" extends keyof Client["Players"][number] ? true : false, false>>,
    Assert<Equal<"Hidden" extends keyof Client["Public"] ? true : false, false>>,
    Assert<Equal<"Set" extends keyof Data ? true : false, false>>,
    Assert<Equal<"Set" extends keyof Data["Doubled"] ? true : false, false>>,
    Assert<Equal<"Increment" extends keyof Data["Doubled"] ? true : false, false>>,
    Assert<Equal<"Child" extends keyof Data["Position"] ? true : false, false>>,
    Assert<Equal<"Child" extends keyof Data["Blob"] ? true : false, false>>
];

type PathsTemplate = {
    Coins: number;
    Stats: { Wins: number; Title: string };
    Wealth: Scribe.BigSchema;
    Secret: Scribe.ServerOnly<number>;
    Derived: Scribe.Derived<number>;
    Timer: Scribe.Timed<number>;
    Values: Scribe.ArrayOf<number>;
    Map: Scribe.MapOf<"integer", number>;
    Position: Vector3;
    Blob: buffer;
};
type Keys = "K00" | "K01" | "K02" | "K03" | "K04" | "K05" | "K06" | "K07" | "K08" | "K09"
    | "K10" | "K11" | "K12" | "K13" | "K14" | "K15" | "K16" | "K17" | "K18" | "K19"
    | "K20" | "K21" | "K22" | "K23" | "K24" | "K25" | "K26" | "K27" | "K28" | "K29"
    | "K30" | "K31" | "K32" | "K33" | "K34" | "K35" | "K36" | "K37" | "K38" | "K39"
    | "K40" | "K41" | "K42" | "K43" | "K44" | "K45" | "K46" | "K47" | "K48" | "K49";
type LargeTemplate = { [K in Keys]: { Value: number; Label: string } };
export type PathAndLargeAssertions = [
    Assert<Equal<Scribe.NumericPaths<PathsTemplate>, "Coins" | "Stats.Wins" | "Secret" | "Derived" | "Timer">>,
    Assert<Equal<Scribe.NumericPaths<PathsTemplate, true>, "Coins" | "Stats.Wins" | "Secret" | "Derived" | "Timer" | "Wealth">>,
    Assert<Equal<Scribe.NumericPaths<LargeTemplate>, `${Keys}.Value`>>,
    Assert<Equal<GetValue<Scribe.PlayerData<LargeTemplate>["K49"]["Value"]>, number>>,
    Assert<Equal<IsAny<GetValue<Scribe.PlayerData<LargeTemplate>>>, false>>,
    Assert<Equal<Scribe.ValueOf<{ Required: number; Note: Scribe.Optional<string> }>, { Required: number; Note?: string }>>
];

export function checkSchema(data: Data, client: Client): void {
    const calledRead: number = data.Coins();
    const calledSet: number = data.Coins(5);
    const calledUpdate: number = data.Coins(current => current + 1, false);
    const calledRoot: Scribe.DeepReadonly<Scribe.ValueOf<Schema>> = data();
    const calledMissing: number | undefined = data.Items.Child("Sword").Quantity();
    const calledOptional: string | undefined = data.Note(undefined);
    const calledDerived: number = data.Doubled();
    data.Players.Child(1)({ Level: 3 });
    data.Players.Child(1)(current => ({ Level: (current?.Level ?? 0) + 1 }));
    print(calledRead, calledSet, calledUpdate, calledRoot, calledMissing, calledOptional, calledDerived);
    data.Coins.Set(5);
    data.Coins.Increment(1, { TransactionType: "QuestReward", ItemSku: "quest-1" });
    data.Coins.Decrement(1, false);
    data.Wealth.Increment("1e50", { Currency: "Stars", Flow: "Source" });
    data.Enabled.Toggle();
    data.Title.Set("Member");
    data.Note.Set(undefined);
    data.Settings.Set({ Music: false, Volume: 0.5 });
    data.Settings.Update(current => ({ Music: !current.Music, Volume: current.Volume }));
    data.Players.Insert({ Name: "Ava" });
    data.Players.Insert({ Detail: { Wins: 2 } });
    data.Players.Set([{ Name: "Ava" }, {}]);
    data.Players.Child(1).Set({ Level: 5 });
    data.Players.Child(1).Detail.Set({ Wins: 2 });
    data.Players.Child(1).Update(current => ({ Level: (current?.Level ?? 0) + 1 }));
    data.Items.Child("Sword").Set({ Quantity: 2 });
    data.Items.Set({ Sword: {}, Shield: { Note: "Favorite" } });
    data.StringMap.Set(new Map([ ["Ava", { Score: 2 }] ]));
    data.StringMap.Child("Ava").Set({ Score: 3 });
    data.IntegerMap.Child(42).Set("Ava");
    const maybeLevel: number | undefined = data.Players.Child(1).Level.Get();
    const maybeEntry: Scribe.DeepReadonly<Scribe.ValueOf<PlayerSchema>> | undefined = data.Players.Child(1).Get();
    const defaultLevel: number = data.Players.Child(1).Level.Default();
    print(maybeLevel, maybeEntry, defaultLevel);
    const collisionNumber: number = data.Collision.Child("Get").Get();
    const collisionString: string = data.Collision.Child("Child").Get();
    const collisionSnapshot: number = data.Collision.Get().Get;
    print(collisionNumber, collisionString, collisionSnapshot);
    data.Flags.Enable("Move");
    data.Flags.Toggle("Combat");
    data.Flags.Set(["Move"]);
    data.Unlocks.Add("Blue");
    data.Unlocks.Remove("Red");
    const index: number | undefined = data.Unlocks.Find("Blue");
    print(index);
    data.Timed.SetTimed(true, 60);
    const [active, remaining] = data.Timed.Active();
    print(active, remaining);
    const [clientActive, clientRemaining] = client.Timed.Active();
    const clientActiveCheck: boolean = clientActive;
    const clientRemainingCheck: number | undefined = clientRemaining;
    print(clientActiveCheck, clientRemainingCheck);
    // @ts-expect-error Active returns a boolean, not a numeric flag.
    const invalidActive: number = clientActive;
    // @ts-expect-error Remaining time is numeric or absent.
    const invalidRemaining: string = clientRemaining;
    print(invalidActive, invalidRemaining);
    data.Wealth.Set("1e200");
    data.Wealth.Set(20);
    data.Wealth.Set(data.Wealth.Get().Add("1e100").Pow(2));
    const comparison: number = data.Wealth.Get().Compare(1);
    const equals: boolean = data.Wealth.Get().Equals("1e100");
    print(comparison, equals);
    data.Position.Set(Vector3.one);
    data.Pose.Set(CFrame.identity);
    data.Blob.Set(buffer.create(8));
    const blob: buffer = data.Blob.Clone();
    print(blob);
    const mutable = data.Settings.Clone();
    mutable.Volume = 0.75;
    data.Settings.Set(mutable);
    client.Players.Insert({ Name: "Visible" });
    client.Items.Child("Sword").Quantity.Observe(count => print(count));

    // @ts-expect-error Numeric fields cannot receive strings.
    data.Coins.Set("5");
    // @ts-expect-error Big inputs must be numeric strings, numbers, or actual Big values.
    data.Wealth.Set({ M: "1", E: 100 });
    // @ts-expect-error A missing exponent is not a Big value.
    data.Wealth.Increment({ M: 1 });
    // @ts-expect-error Stored Big arrays are not public Big operands.
    data.Wealth.Multiply([1, 100]);
    // @ts-expect-error Arithmetic methods preserve the same operand contract.
    data.Wealth.Get().Add({ M: 1, E: "100" });
    // @ts-expect-error A schema marker is not a runtime Big value.
    data.Wealth.Set(Scribe.Big("1e100"));
    // @ts-expect-error Big defaults are scalar inputs, not unchecked mantissa/exponent tables.
    Scribe.Big({ M: 1, E: 100 });
    // @ts-expect-error Big bounds accept numbers or numeric strings.
    Scribe.Big(0, { Max: { M: 1, E: 100 } });
    // @ts-expect-error The exponent passed to Pow is a number.
    data.Wealth.Get().Pow("2");
    // @ts-expect-error Callable setter shorthand checks the field's input type.
    data.Coins("5");
    // @ts-expect-error Callable updater shorthand checks its returned value.
    data.Coins(current => tostring(current));
    // @ts-expect-error Root callable shorthand is read-only.
    data({});
    // @ts-expect-error The client API proxy cannot be called as a setter.
    client({});
    // @ts-expect-error The client API proxy itself has no __call; its field accessors do.
    client();
    // @ts-expect-error Derived callable shorthand is read-only.
    data.Doubled(5);
    // @ts-expect-error Derived callable shorthand cannot update either.
    data.Doubled((current: number) => current + 1);
    // @ts-expect-error Economy metadata is passed directly, not through an invented wrapper.
    data.Coins.Increment(1, { Meta: { Currency: "Coins" } });
    // @ts-expect-error Enum writes preserve their declared members.
    data.Title.Set("Owner");
    // @ts-expect-error Flag names preserve their declared members.
    data.Flags.Enable("Fly");
    // @ts-expect-error Set element types remain exact.
    data.Unlocks.Add("Green");
    // @ts-expect-error A set has membership operations, not array insertion.
    data.Unlocks.Insert("Red");
    // @ts-expect-error An array does not gain set operations.
    data.Players.Add({});
    // @ts-expect-error Integer-map keys are numbers without array index shifting.
    data.IntegerMap.Child("42");
    // @ts-expect-error String maps reject numeric keys.
    data.StringMap.Remove(42);
    // @ts-expect-error Whole-map writes must be maps, not an element value.
    data.IntegerMap.Set("Ava");
    // @ts-expect-error An integer-map element does not make its container a string scalar.
    data.IntegerMap.Increment(1);
    // @ts-expect-error Partial element records still check provided field types.
    data.Players.Insert({ Level: "bad" });
    // @ts-expect-error Declared element records reject unknown keys.
    data.Items.Child("Sword").Set({ Quantity: 1, Typo: true });
    // @ts-expect-error Plain array elements have no declarator defaults to fill missing fields.
    data.PlainArray.Insert({ Name: "Ava" });
    // @ts-expect-error An untyped array nested in a declared element still has no element defaults.
    data.Players.Child(1).Raw.Insert({ Name: "Ava" });
    // @ts-expect-error Whole-element writes preserve the same raw-container boundary.
    data.Players.Insert({ Raw: [{ Name: "Ava" }] });
    // @ts-expect-error Nested raw-array entries require their full record.
    data.Players.Child(1).Raw.Child(1).Set({ Name: "Ava" });
    // @ts-expect-error Ordinary record writes require their nonoptional fields.
    data.Settings.Set({ Music: true });
    // @ts-expect-error Dynamic elements and their descendants can be absent.
    const requiredLevel: number = data.Players.Child(1).Level.Get();
    // @ts-expect-error Optional fields cannot be read as always present.
    const requiredNote: string = data.Note.Get();
    // @ts-expect-error The whole player root cannot be replaced.
    data.Set({});
    // @ts-expect-error The whole player root cannot be updated.
    data.Update(() => ({}));
    // @ts-expect-error Derived nodes omit writes.
    data.Doubled.Set(5);
    // @ts-expect-error Derived nodes omit numeric mutations as well.
    data.Doubled.Increment(5);
    // @ts-expect-error Server-only roots do not exist on the client.
    client.Secret.Quantity.Get();
    // @ts-expect-error Server-only fields inside dynamic elements are also removed.
    client.Players.Child(1).Hidden.Get();
    // @ts-expect-error Server-only fields nested in shared roots are removed.
    client.Public.Hidden.Get();
    // @ts-expect-error Roblox datatypes are atomic values, not accessor subtrees.
    data.Position.X.Get();
    // @ts-expect-error Buffers are atomic values, not nominal-type accessor subtrees.
    data.Blob.Child("_nominal_buffer");
    // @ts-expect-error Native datatype writes do not accept partial object shapes.
    data.Position.Set({ X: 0 });
    // @ts-expect-error Numeric array macros must not be available on accessor proxies.
    data.Players.push({});
    // @ts-expect-error Read snapshots cannot bypass validated writes.
    data.Settings.Get().Volume = 1;
    // @ts-expect-error A dictionary key named Get cannot turn the getter itself into a data node.
    data.Items.Get.Set({ Quantity: 1 });
    print(requiredLevel, requiredNote);
}

export function checkClientAPICollision(client: Scribe.ClientData<{ Request: number }>): void {
    const value: number = client.Child("Request").Get();
    print(value);
    // @ts-expect-error Real API properties shadow same-named fields; Child reaches the field.
    client.Request.Get();
}

type StoreSchema = { State: { Enabled: boolean; Score: number }; Items: Scribe.DictOf<{ Quantity: number }>; Wealth: Scribe.BigSchema; Flags: Scribe.Flags<"One"> };
export function checkReadonlyStore(client: Scribe.ClientData<{}, StoreSchema>): void {
    const score: number = client.ServerStore.State.Score.Get();
    const calledScore: number = client.ServerStore.State.Score();
    const count: number | undefined = client.ServerStore.Items.Child("A").Quantity.Get();
    print(score, calledScore, count);
    // @ts-expect-error Client store callable shorthand exposes only reads.
    client.ServerStore.State.Score(5);
    // @ts-expect-error Client store callable shorthand cannot update either.
    client.ServerStore.State.Score((current: number) => current + 1);
    // @ts-expect-error Client store roots are read-only.
    client.ServerStore.State.Set({ Enabled: true, Score: 1 });
    // @ts-expect-error Client store nested fields stay read-only.
    client.ServerStore.State.Score.Increment(1);
    // @ts-expect-error Client store dynamic element fields stay read-only.
    client.ServerStore.Items.Child("A").Quantity.Set(2);
    // @ts-expect-error Client store Big nodes do not expose mutators.
    client.ServerStore.Wealth.Multiply(2);
    // @ts-expect-error Client store Flags do not expose mutators.
    client.ServerStore.Flags.Enable("One");
}

// ServerStore is a plain root map: accessor method names remain ordinary fields.
const collisionStoreTemplate = {
    Get: Scribe.Int(0),
    Set: Scribe.String("Lobby"),
    Changed: false,
    Child: { Enabled: true },
    ServerStore: Scribe.ArrayOf(Scribe.String("")),
    Secret: Scribe.ServerOnly({ Seed: Scribe.Int(0) }),
    Entries: Scribe.DictOf({ Amount: Scribe.Int(0), Hidden: Scribe.ServerOnly(false) }),
    DoubleGet: Scribe.Derived(Scribe.Int(0), ["Get"], (value: number) => value * 2),
};
type CollisionStoreTemplate = typeof collisionStoreTemplate;
type CollisionStore = Scribe.ServerStore<CollisionStoreTemplate>;
type ClientCollisionStore = Scribe.ClientServerStore<CollisionStoreTemplate>;
export type ServerStoreAssertions = [
    Assert<Equal<keyof CollisionStore, keyof CollisionStoreTemplate>>,
    Assert<Equal<GetValue<CollisionStore["Get"]>, number>>,
    Assert<Equal<GetValue<CollisionStore["Set"]>, string>>,
    Assert<Equal<GetValue<CollisionStore["Changed"]>, boolean>>,
    Assert<Equal<GetValue<CollisionStore["Child"]["Enabled"]>, boolean>>,
    Assert<Equal<"Secret" extends keyof ClientCollisionStore ? true : false, false>>,
    Assert<Equal<"Hidden" extends keyof ClientCollisionStore["Entries"][string] ? true : false, false>>,
    Assert<Equal<"Set" extends keyof CollisionStore["DoubleGet"] ? true : false, false>>,
    Assert<Equal<IsAny<GetValue<CollisionStore["Get"]>>, false>>
];

export function checkStoreRootNames(): void {
    const callable = Scribe({
        Template: { Coins: Scribe.Int(0) },
        ServerStore: collisionStoreTemplate,
        ProfileStoreIndex: "CollisionStoreCallable",
        ProfileKeyPrefix: "PLAYER_",
    });
    const named = Scribe.new({
        Template: { Coins: Scribe.Int(0) },
        ServerStore: collisionStoreTemplate,
        ProfileStoreIndex: "CollisionStoreNamed",
        ProfileKeyPrefix: "PLAYER_",
    });
    const namedGet: number = callable.Server.ServerStore.Get.Increment(1);
    const namedSet: string = named.Server.ServerStore.Set.Set("Playing");
    const namedChanged: boolean = callable.Client.ServerStore.Changed.Get();
    const namedChild: boolean = named.Client.ServerStore.Child.Enabled.Get();
    callable.Server.ServerStore.Child.Set({ Enabled: false });
    named.Server.ServerStore.ServerStore.Insert("Alice");
    named.Server.ServerStore.Entries.Child("Sword").Set({ Amount: 1 });
    const maybeName: string | undefined = named.Client.ServerStore.ServerStore.Child(1).Get();
    const doubled: number = named.Client.ServerStore.DoubleGet.Get();
    print(namedGet, namedSet, namedChanged, namedChild, maybeName, doubled);
    // @ts-expect-error Root map Get is the declared number accessor, not a map snapshot getter.
    const snapshot: Scribe.ValueOf<CollisionStoreTemplate> = callable.Server.ServerStore.Get();
    // @ts-expect-error Store roots preserve their input types despite colliding method names.
    named.Server.ServerStore.Get.Set("one");
    // @ts-expect-error Client store fields remain read-only when named after accessor methods.
    callable.Client.ServerStore.Set.Set("Playing");
    // @ts-expect-error Server-only store roots are absent on the client.
    named.Client.ServerStore.Secret.Seed.Get();
    // @ts-expect-error Server-only children inside store collections are also absent on the client.
    named.Client.ServerStore.Entries.Child("Sword").Hidden.Get();
    // @ts-expect-error Derived store nodes have no mutation shorthand.
    named.Server.ServerStore.DoubleGet(5);
    // @ts-expect-error Player template fields do not leak into the store map.
    named.Server.ServerStore.Coins.Get();
    // @ts-expect-error The store map does not gain undeclared accessor observer methods.
    named.Server.ServerStore.Observe(() => {});
    print(snapshot);
}
