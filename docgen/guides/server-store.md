# The Server Store

Some state belongs to the **server**, not to any player. The wave number in a round, the boss's health bar, which map is loading, how many seconds are left on the intermission clock. Every player sees the same value, nobody owns it, and none of it should ever be saved.

Before, the only way to replicate that was to pick a player at random and hang it off their profile, or to build a second networking layer beside Scribe. The server store is that state declared where it belongs.

```lua
return Scribe({
    Template = template,
    ProfileStoreIndex = "EmberfallPlayerData",
    ProfileKeyPrefix = "PLAYER_",

    ServerStore = {
        Wave         = Scribe.Int(1, { Min = 1 }),
        BossHp       = Scribe.Int(0, { Min = 0 }),
        Intermission = Scribe.Number(0, { Min = 0 }),
    },
})
```

That is the whole setup. `ServerStore` sits beside `Template`, takes the same declarators, and produces one tree for the whole server.

## Reading and writing it

On the server, `Data.ServerStore` holds the roots you declared, and every accessor works exactly as it does on a player's data:

```lua
Data.ServerStore.Wave.Increment(1)
Data.ServerStore.BossHp.Set(5000)

Data.ServerStore.BossHp.Changed(function(hp)
    if hp <= 0 then
        endWave()
    end
end)
```

On the client it is the same name on the same table, read-only like the rest of the client's mirror:

```lua
local Data = require(ReplicatedStorage.Shared.EmberfallData).Client

Data.ServerStore.Wave.Observe(function(wave)
    waveLabel.Text = `Wave {wave}`
end)
```

There is no player argument anywhere, on either side. The store exists from the moment the bundle is built, so the server can write it with nobody in the game yet, and a player who joins during wave 7 receives 7 in the same Init snapshot that carries their own profile.

!!! tip "It is one table, not one per player"
    `Data.ServerStore.Wave.Set(7)` is a single write no matter how many players are connected. Scribe fans the resulting op out to every ready client, so the cost of a write grows with the number of players, but the state does not.

## Nothing in it is saved

A store root has no DataStore key behind it. It is not in any profile payload, it does not mark a profile dirty, it is not in the per-player session store, and `Data.Flush` never sees it. When the server closes, the store goes with it.

That is the point rather than a limitation: round state that outlived its round would be worse than useless. Anything that must survive a server, like a player's best wave, is ordinary template data on that player's profile.

## Visibility

Every store root replicates to every client by default, which is what makes it useful. To keep one server-side, declare it `Scribe.ServerOnly`:

```lua
ServerStore = {
    Wave = Scribe.Int(1),
    Seed = Scribe.ServerOnly(0),   -- the RNG seed clients must not read
}
```

`Scribe.ServerOnly` is the only visibility declarator a store root takes. [`Scribe.Shared`](./visibility) is refused, because it means "send this player's field to everyone" and a store root already reaches everyone.

## What a store may not declare

Scribe refuses these at startup, with a message naming the field:

| Refused | Why |
| --- | --- |
| A name the `Template` already declares | The two share one id space, so a name can only mean one thing. |
| `Scribe.Session` | A store is never saved, so marking a field unsaved says nothing new. |
| `Scribe.Shared` | Every store root already reaches every client. |
| `Scribe.Timed` | A deadline is swept per profile, and a store has no profile. |
| `Scribe.Dynamic` | The factory is sampled per profile load, which never happens here. |
| `Scribe.Derived` reading across the boundary | A derived field recomputes on the tree that took the write, and these are two trees. |
| A `_Scribe` prefix | Library-owned, the same as in your template. |

Containers, records, `Scribe.Big`, bounds, and derived fields whose inputs stay on one side all work normally.

## Transactions

A store write from inside `Data.Transaction` is refused:

```lua
Data.Transaction(player, function()
    data.Coins.Increment(-100)
    Data.ServerStore.BossHp.Decrement(50)  -- refused, and the transaction aborts
end)
```

A rollback restores one player's tree. The store is not that tree and is not saved to any key, so a store write made inside a transaction would outlive an abort and leave the two halves disagreeing. Write the store before the transaction, or after it returns `true`:

```lua
local ok = Data.Transaction(player, function()
    data.Coins.Increment(-100)
    data.Tickets.Increment(1)
end)

if ok then
    Data.ServerStore.BossHp.Decrement(50)
end
```

## What it costs

Measured on Scribe {{version}}:

- **Memory**: about 3 KB for the store tree, and it stayed flat as roots were added. It is one tree for the server, so nothing about it scales with player count.
- **A write**: one op, fanned out to each ready client, about 16 bytes per client for an integer field. Sixty-four players with a store field written every single frame came to a third of a millisecond in the worst flush.
- **Joining**: about 2 bytes per store field in the Init snapshot.

A store field written every frame is cheaper than the same value sent through a RemoteEvent per player, because the ops share a frame buffer with the rest of replication. It is still a per-player cost, so a value that changes sixty times a second and is only read once a second is better written once a second.

## Where to next

- [Replication & Visibility](./visibility) covers `Scribe.ServerOnly` and the rest of the visibility rules.
- [Declaring Your Template](./templates) covers every declarator a store root can use.
- [Cross-Key Transactions](./transactions) explains why a rollback cannot reach the store.
- [Commands & Requests](./commands) is how a client asks the server to change something the store shows.
- [Configuration](./configuration) lists `ServerStore` beside every other option.
