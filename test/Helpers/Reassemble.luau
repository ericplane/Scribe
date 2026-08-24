--!strict
-- Collapses a captured frame log back into LOGICAL frames.
--
-- Scribe splits any outbound frame over MaxOutboundBytes into Fragment frames
-- (Wire.Fragment) and the real client rebuilds them. A test reading raw bytes off
-- a transport log sees the pieces instead, and byte 0 of a piece is
-- Frames.Fragment rather than the frame type the spec is looking for -- so an
-- assertion like "exactly one Init frame" silently counts ZERO the moment a
-- profile grows past the budget, which is the opposite of failing loudly.
--
-- Deliberately NOT a copy of the client's reassembler: this one is offline and
-- total, so it has no sequence state to get wrong. It reassembles a run of
-- fragments in log order and refuses anything that is not one.
local Wire = require(script.Parent.Parent.Parent.Scribe.Internal.Wire)

local Reassemble = {}

export type Frame = { Player: any?, Bytes: buffer }

--- Returns `frames` with every run of Fragment frames replaced by the single
--- logical frame it carries. Frames that are not fragments pass through
--- untouched, including ones interleaved between fragments of the same frame.
function Reassemble.Logical(frames: { Frame }): { Frame }
	local out: { Frame } = {}
	local pending: { Frame } = {}
	local written, total, seq = 0, 0, -1
	local dest: buffer? = nil

	for _, frame in frames do
		local bytes = frame.Bytes
		if buffer.len(bytes) < 1 or buffer.readu8(bytes, 0) ~= Wire.Frames.Fragment then
			table.insert(out, frame)
			continue
		end
		local fragSeq = buffer.readu16(bytes, 1)
		local declared = buffer.readu32(bytes, 3)
		local index = buffer.readu16(bytes, 7)
		local payload = buffer.len(bytes) - Wire.FRAGMENT_HEADER
		if index == 0 then
			dest, total, written, seq = buffer.create(declared), declared, 0, fragSeq
			pending = {}
		end
		local target = dest
		if target == nil or fragSeq ~= seq or written + payload > total then
			-- Not a run this helper can rebuild. Pass the pieces through so the spec
			-- sees something wrong rather than nothing at all.
			for _, held in pending do
				table.insert(out, held)
			end
			table.insert(out, frame)
			dest, total, written, seq, pending = nil, 0, 0, -1, {}
			continue
		end
		buffer.copy(target, written, bytes, Wire.FRAGMENT_HEADER, payload)
		written += payload
		table.insert(pending, frame)
		if written == total then
			table.insert(out, { Player = frame.Player, Bytes = target })
			dest, total, written, seq, pending = nil, 0, 0, -1, {}
		end
	end
	for _, held in pending do
		table.insert(out, held)
	end
	return out
end

return Reassemble
