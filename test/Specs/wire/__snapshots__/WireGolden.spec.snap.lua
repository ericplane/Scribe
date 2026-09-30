-- Jest Roblox Snapshot v1, http://roblox.github.io/jest-roblox/snapshot-testing
local exports = {}
exports[ [=[keeps the diff encoding stable for dynamic paths and collection operations 1]=] ] = [=[

Table {
  "Hex": "03 05 00 11 04 01 01 05 53 77 6f 72 64 01 03 00 00 00 00 00 00 39 40 01 04 01 01 04 47 6f 6e 65 32 05 00 01 01 04 07 73 74 61 72 74 65 72 23 05 00 01 04 04 00",
  "ProtocolVersion": 6,
}
]=]

exports[ [=[keeps the diff encoding stable for schema values 1]=] ] = [=[

Table {
  "Hex": "03 04 00 11 02 00 00 01 04 11 03 00 00 09 11 06 00 00 01 11 01 00 00 00",
  "ProtocolVersion": 6,
}
]=]

return exports
