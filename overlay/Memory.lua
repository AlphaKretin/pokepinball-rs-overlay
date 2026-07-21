-- Domain-aware memory reads: takes a full GBA address (e.g. 0x02000000)
-- and dispatches to the correct BizHawk memory domain automatically.
-- Pattern lifted from reference/ProfOakTASOverlay/scripts/Memory.lua.

Memory = {}

local DOMAINS = {
	[0x00] = "BIOS",
	[0x02] = "EWRAM",
	[0x03] = "IWRAM",
	[0x08] = "ROM",
}

function Memory.read(addr, size)
	local domain = DOMAINS[addr >> 24]
	local offset = addr & 0xFFFFFF
	if size == 1 then
		return memory.read_u8(offset, domain)
	elseif size == 2 then
		return memory.read_u16_le(offset, domain)
	elseif size == 4 then
		return memory.read_u32_le(offset, domain)
	end
end

function Memory.readbyte(addr)
	return Memory.read(addr, 1)
end

function Memory.readword(addr)
	return Memory.read(addr, 2)
end

function Memory.readdword(addr)
	return Memory.read(addr, 4)
end
