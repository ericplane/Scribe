# Using the reference

Use these pages to look up a function, option, type, or log code. To build your first working example, start with [Getting Started](./intro). For a feature such as an inventory or shop, [choose a recipe](./recipes).

## Which API page do I need?

| Page | What you will find |
| --- | --- |
| [Scribe](/api/Scribe) | Creating a data module, field declarations, and shared diagnostics. |
| [Server](/api/Server) | Loading and saving profiles, commands, purchases, and offline operations. |
| [Client](/api/Client) | Waiting for initial data, sending requests, and reading client-side feature state. |
| [Value](/api/Value) | Methods on a field, such as `Get`, `Set`, `Observe`, and container operations. |
| [BigValue](/api/BigValue) | Reading and changing a big-number field. |
| [Types](/api/Types) | Option tables, return shapes, and named types used in signatures. |
| [Signal](/api/Signal) and [Connection](/api/Connection) | Subscribing to events and disconnecting listeners. |

Each larger API page begins with a member index. Follow a link to its signature and behavior. A **server** or **client** badge tells you where to call it; a **yields** badge means the calling thread may wait before the function returns.

## Reading a signature

`player: Player` means you pass a Player object. A `?`, as in `timeout: number?`, means the value is optional. A tuple such as `(boolean, string?)` means there are multiple return values: here, a boolean followed by an optional string.

Read the return description as well as the type. A `false` result can mean different things for different functions. For example, an unconfirmed `Flush` can still finish later, so repeating the purchase would be the wrong response.

## Configuration and troubleshooting

- [Configuration](./configuration) lists the options you can pass to Scribe. Start with defaults and change the options your game needs.
- [Log codes](./log-codes) explains diagnostic entries. Log codes and function return reasons are different things; use the documented return contract when branching on a function's result.
- [Troubleshooting](./troubleshooting) starts with symptoms rather than API names.

The signatures and API descriptions are generated from the library source. The documentation version should match the Scribe version you have installed.
