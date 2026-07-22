-- Self-extracts overlay images directly from the loaded ROM into
-- images/{areas,portraits,egg_hatch}/, once per file, so the repo ships no
-- copyrighted sprite/icon assets. Every address/format used here was
-- verified offline against the actual ROM (SHA1
-- 9fec81ce2c5df589e0371a0bf2f92a5fe8db730b) and its pret/pokepinballrs decomp
-- before being ported to Lua -- see docs/graphics-extraction.md for how each 
-- address/layout was derived.
--
-- Nothing here is LZ77-compressed (verified for all three asset types), so
-- this is pure byte-offset arithmetic + a from-scratch PNG writer -- no
-- decompression needed, matching scripts/gba_gfx.py's approach.

GfxExtract = {}

local TILE_SIZE_PX = 8
local BYTES_PER_TILE = 32

-- Directory/filename conventions -- must match Overlay.lua's PORTRAIT_DIR/
-- AREA_ICON_DIR/EGG_ICON_DIR and its imageKey() function exactly, since
-- that's what actually loads these files back at draw time.
local PORTRAIT_DIR = "images/portraits/"
local AREA_ICON_DIR = "images/areas/"
local EGG_ICON_DIR = "images/egg_hatch/"

local function imageKey(name)
	return name:lower():gsub("[ '.]", "")
end

-- ---------------------------------------------------------------------------
-- ROM tile/palette decoding (GBA 4bpp indexed tiles, BGR555 palettes)

local function bgr555ToRgb(color)
	local r = (color & 0x1F) * 255 // 31
	local g = ((color >> 5) & 0x1F) * 255 // 31
	local b = ((color >> 10) & 0x1F) * 255 // 31
	return { r, g, b }
end

local function readPalette(addr, numColors)
	numColors = numColors or 16
	local pal = {}
	for i = 0, numColors - 1 do
		pal[i] = bgr555ToRgb(Memory.readword(addr + i * 2))
	end
	return pal
end

local function readBytes(addr, len)
	local bytes = {}
	for i = 0, len - 1 do
		bytes[i] = Memory.readbyte(addr + i)
	end
	return bytes
end

-- Returns an 8x8 (row-major) grid of palette indices for one tile. 4bpp GBA
-- tiles pack two pixels per byte, low nibble first (left pixel).
local function decodeTile4bpp(bytes, tileIndex)
	local base = tileIndex * BYTES_PER_TILE
	local tile = {}
	for row = 0, 7 do
		tile[row] = {}
		local rowBase = base + row * 4
		for colByte = 0, 3 do
			local b = bytes[rowBase + colByte]
			tile[row][colByte * 2] = b & 0xF
			tile[row][colByte * 2 + 1] = (b >> 4) & 0xF
		end
	end
	return tile
end

-- Assembles tiles stored in pret's "gfx-config" metatile order: a metaWide x
-- metaTall grid of metatiles, each metatile mWidth x mHeight tiles
-- (row-major within the metatile), metatiles themselves row-major.
-- mWidth=mHeight=1 degenerates to plain raster order. Used for area icons
-- and portraits (both DMA'd into VRAM identically at runtime -- see
-- docs/graphics-extraction.md).
local function assembleMetatileImage(bytes, metaWide, metaTall, mWidth, mHeight)
	local w, h = metaWide * mWidth * TILE_SIZE_PX, metaTall * mHeight * TILE_SIZE_PX
	local img = {}
	for y = 0, h - 1 do
		img[y] = {}
	end
	local idx = 0
	for my = 0, metaTall - 1 do
		for mx = 0, metaWide - 1 do
			for ty = 0, mHeight - 1 do
				for tx = 0, mWidth - 1 do
					local tile = decodeTile4bpp(bytes, idx)
					local px = (mx * mWidth + tx) * TILE_SIZE_PX
					local py = (my * mHeight + ty) * TILE_SIZE_PX
					for r = 0, 7 do
						for c = 0, 7 do
							img[py + r][px + c] = tile[r][c]
						end
					end
					idx = idx + 1
				end
			end
		end
	end
	return img, w, h
end

-- Egg-hatch sprite frames are NOT a flat tile raster: the 24x24 frame is
-- composited at runtime from 4 separate GBA OBJs (16x16 + 8x16 + 16x8 + 8x8,
-- gCatchCreatureOamFramesets in the decomp), all reading from one fixed
-- 9-tile/288-byte block. {tileIndex, screenX, screenY} per tile.
local EGG_HATCH_TILE_PLACEMENTS = {
	{ 0, 0, 0 }, { 1, 8, 0 }, { 2, 0, 8 }, { 3, 8, 8 }, -- 16x16 OBJ
	{ 4, 16, 0 }, { 5, 16, 8 }, -- 8x16 OBJ
	{ 6, 0, 16 }, { 7, 8, 16 }, -- 16x8 OBJ
	{ 8, 16, 16 }, -- 8x8 OBJ
}

local function assembleEggHatchFrame(bytes)
	local img = {}
	for y = 0, 23 do
		img[y] = {}
	end
	for _, placement in ipairs(EGG_HATCH_TILE_PLACEMENTS) do
		local tileIndex, px, py = placement[1], placement[2], placement[3]
		local tile = decodeTile4bpp(bytes, tileIndex)
		for r = 0, 7 do
			for c = 0, 7 do
				img[py + r][px + c] = tile[r][c]
			end
		end
	end
	return img
end

-- ---------------------------------------------------------------------------
-- Minimal PNG writer. Uses uncompressed ("stored") DEFLATE blocks for the
-- zlib/IDAT stream instead of a real compressor -- every image extracted
-- here is small enough (well under the 65535-byte stored-block limit) that
-- no compression is needed, just correct framing.

local CRC_TABLE = {}
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		if c & 1 == 1 then
			c = 0xEDB88320 ~ (c >> 1)
		else
			c = c >> 1
		end
	end
	CRC_TABLE[n] = c
end

local function crc32(bytes)
	local c = 0xFFFFFFFF
	for i = 1, #bytes do
		c = CRC_TABLE[(c ~ bytes[i]) & 0xFF] ~ (c >> 8)
	end
	return c ~ 0xFFFFFFFF
end

local function adler32(bytes)
	local a, b = 1, 0
	for i = 1, #bytes do
		a = (a + bytes[i]) % 65521
		b = (b + a) % 65521
	end
	return (b << 16) | a
end

local function u32be(n)
	return { (n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF }
end

local function appendAll(dst, src)
	local n = #dst
	for i = 1, #src do
		dst[n + i] = src[i]
	end
end

local function bytesToString(bytes)
	local chars = {}
	for i = 1, #bytes do
		chars[i] = string.char(bytes[i])
	end
	return table.concat(chars)
end

local function pngChunk(tag, data)
	local typeAndData = { tag:byte(1), tag:byte(2), tag:byte(3), tag:byte(4) }
	appendAll(typeAndData, data)
	local chunk = {}
	appendAll(chunk, u32be(#data))
	appendAll(chunk, typeAndData)
	appendAll(chunk, u32be(crc32(typeAndData)))
	return chunk
end

-- One or more "stored" (uncompressed) DEFLATE blocks, each up to 65535 bytes.
local function deflateStored(raw)
	local out = {}
	local pos = 1
	local total = #raw
	repeat
		local remaining = total - pos + 1
		local blockLen = math.min(remaining, 65535)
		local isFinal = (pos + blockLen - 1) >= total
		local notLen = (~blockLen) & 0xFFFF
		local header = {
			isFinal and 1 or 0,
			blockLen & 0xFF, (blockLen >> 8) & 0xFF,
			notLen & 0xFF, (notLen >> 8) & 0xFF,
		}
		appendAll(out, header)
		for i = pos, pos + blockLen - 1 do
			out[#out + 1] = raw[i]
		end
		pos = pos + blockLen
	until pos > total
	return out
end

-- palette: {r,g,b} per index. hasAlpha: writes RGBA, with alphaIndex
-- transparent (alpha 0) and everything else opaque.
local function writePng(path, img, palette, w, h, hasAlpha, alphaIndex)
	local raw = {}
	for y = 0, h - 1 do
		raw[#raw + 1] = 0 -- no per-scanline filter
		for x = 0, w - 1 do
			local idx = img[y][x]
			local color = palette[idx]
			raw[#raw + 1] = color[1]
			raw[#raw + 1] = color[2]
			raw[#raw + 1] = color[3]
			if hasAlpha then
				raw[#raw + 1] = (idx == alphaIndex) and 0 or 255
			end
		end
	end

	local zlibStream = { 0x78, 0x01 }
	appendAll(zlibStream, deflateStored(raw))
	appendAll(zlibStream, u32be(adler32(raw)))

	local ihdr = {}
	appendAll(ihdr, u32be(w))
	appendAll(ihdr, u32be(h))
	appendAll(ihdr, { 8, hasAlpha and 6 or 2, 0, 0, 0 })

	local out = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }
	appendAll(out, pngChunk("IHDR", ihdr))
	appendAll(out, pngChunk("IDAT", zlibStream))
	appendAll(out, pngChunk("IEND", {}))

	local f = io.open(path, "wb")
	if not f then
		console.log("GfxExtract: failed to open " .. path .. " for writing")
		return false
	end
	f:write(bytesToString(out))
	f:close()
	return true
end

local function fileExists(path)
	local f = io.open(path, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

-- Users may grab the .lua files individually rather than the whole repo, so
-- images/{areas,portraits,egg_hatch}/ can't be assumed to exist (a tracked
-- placeholder file wouldn't survive that either). BizHawk Lua is
-- Windows-only and os.execute is confirmed available (used elsewhere in the
-- BizHawk Lua community to launch external programs), so a plain cmd.exe
-- mkdir is safe here -- Windows' mkdir already creates intermediate
-- directories, so this alone is enough even though dir is nested under
-- images/. pcall-guarded in case os.execute is ever unavailable; extraction
-- still proceeds and writePng's own io.open failure is the visible symptom
-- if the directory genuinely never gets created.
-- The "if not exist" guard is done in the shell command itself, not in Lua,
-- since io.open can't reliably probe directory (as opposed to file)
-- existence -- so this is safe/idempotent to call every time, not just once.
local function ensureDir(dir)
	-- Strip any trailing slash first -- a trailing backslash immediately
	-- before the closing quote can be misparsed as an escaped quote on
	-- Windows command lines.
	local windowsPath = dir:gsub("/$", ""):gsub("/", "\\")
	local ok = pcall(os.execute, 'if not exist "' .. windowsPath .. '" mkdir "' .. windowsPath .. '"')
	if not ok then
		console.log("GfxExtract: couldn't create " .. dir .. " -- create it manually if extraction fails below")
	end
end

-- ---------------------------------------------------------------------------
-- Area icons: gPortraitGenericGraphics/gPortraitGenericPalettes, 13 unique
-- icons (Ruin Ruby/Sapphire share one asset in-game). 0x0848D68C/0x081C00E4
-- verified against the ROM -- see docs/graphics-extraction.md.
local AREA_GFX_ADDR, AREA_PAL_ADDR = 0x0848D68C, 0x081C00E4
local AREA_ICON_FILES = {
	"forest_ruby_icon", "forest_sapphire_icon",
	"plains_ruby_icon", "plains_sapphire_icon",
	"ocean_ruby_icon", "ocean_sapphire_icon",
	"cave_ruby_icon", "cave_sapphire_icon",
	"safari_zone_icon", "volcano_icon", "lake_icon", "wilderness_icon",
	"ruin_icon",
}

local function extractAreaIcons()
	local count = 0
	local started = false
	for i, name in ipairs(AREA_ICON_FILES) do
		local path = AREA_ICON_DIR .. name .. ".png"
		if not fileExists(path) then
			if not started then
				console.log("GfxExtract: extracting area icons from ROM (first run only)...")
				ensureDir(AREA_ICON_DIR)
				started = true
			end
			local bytes = readBytes(AREA_GFX_ADDR + (i - 1) * 0x300, 0x300)
			local pal = readPalette(AREA_PAL_ADDR + (i - 1) * 0x20, 16)
			local img, w, h = assembleMetatileImage(bytes, 3, 2, 2, 2)
			if writePng(path, img, pal, w, h, false) then
				count = count + 1
			end
		end
	end
	return count
end

-- ---------------------------------------------------------------------------
-- Portraits: gMonPortraitsGroup*_Gfx/_Pals, one per species in SpeciesNames
-- (Data.lua). Gfx groups are flat/contiguous (species*0x300 works directly);
-- palette groups each carry a hidden 16th "silhouette" entry the gfx groups
-- don't, so palette addressing needs group/index split, not a flat multiply
-- -- see docs/graphics-extraction.md.
local PORTRAIT_GFX_ADDR, PORTRAIT_PAL_ADDR = 0x084C596C, 0x0839AB8C

local function extractPortraits()
	local count = 0
	local started = false
	for i = 1, #SpeciesNames do
		local species = i - 1
		local path = PORTRAIT_DIR .. imageKey(SpeciesNames[i]) .. "_portrait.png"
		if not fileExists(path) then
			if not started then
				console.log("GfxExtract: extracting " .. #SpeciesNames .. " portraits from ROM (first run only, may take a moment)...")
				ensureDir(PORTRAIT_DIR)
				started = true
			end
			local group, idxInGroup = species // 15, species % 15
			local bytes = readBytes(PORTRAIT_GFX_ADDR + species * 0x300, 0x300)
			local pal = readPalette(PORTRAIT_PAL_ADDR + group * 0x200 + idxInGroup * 0x20, 16)
			local img, w, h = assembleMetatileImage(bytes, 3, 2, 2, 2)
			if writePng(path, img, pal, w, h, false) then
				count = count + 1
			end
		end
	end
	return count
end

-- ---------------------------------------------------------------------------
-- Egg-hatch sprites: species -> sprite via gDexAnimationIx[species] (s16 @
-- 0x086A61BC). Values: -1 = no animation, <100 = catch-sprite animation (not
-- extracted here), >=100 = hatch sprite, group=(v-100)//6, index=(v-100)%6.
-- Only frame 0 (first 0x120 bytes of the species' 0x10E0-byte blob) is
-- needed. Palette index 0 = transparent (green chroma-key convention).
local DEX_ANIM_IX_ADDR = 0x086A61BC
local HATCH_GFX_GROUPS = { 0x083C8B6C, 0x083CF0AC, 0x083D55EC, 0x083DBB2C, 0x083E206C, 0x083E85AC }
local HATCH_PAL_GROUPS = { 0x081444F4, 0x081446F4, 0x081448F4, 0x08144AF4, 0x08144CF4, 0x08144EF4 }

local function readDexAnimationIx(species)
	local lo = Memory.readbyte(DEX_ANIM_IX_ADDR + species * 2)
	local hi = Memory.readbyte(DEX_ANIM_IX_ADDR + species * 2 + 1)
	local v = lo | (hi << 8)
	if v >= 0x8000 then
		v = v - 0x10000 -- sign-extend s16
	end
	return v
end

local function extractEggHatchIcons()
	local count = 0
	local started = false
	for i = 1, #SpeciesNames do
		local species = i - 1
		local path = EGG_ICON_DIR .. imageKey(SpeciesNames[i]) .. "_hatch.png"
		if not fileExists(path) then
			local v = readDexAnimationIx(species)
			if v >= 100 then
				if not started then
					console.log("GfxExtract: extracting egg-hatch icons from ROM (first run only)...")
					ensureDir(EGG_ICON_DIR)
					started = true
				end
				local group, idxInGroup = (v - 100) // 6, (v - 100) % 6
				local bytes = readBytes(HATCH_GFX_GROUPS[group + 1] + idxInGroup * 0x10E0, 0x120)
				local pal = readPalette(HATCH_PAL_GROUPS[group + 1] + idxInGroup * 0x20, 16)
				local img = assembleEggHatchFrame(bytes)
				if writePng(path, img, pal, 24, 24, true, 0) then
					count = count + 1
				end
			end
		end
	end
	return count
end

-- Runs once at overlay startup (before the main frame loop). Only extracts
-- files that don't already exist, so this is a no-op cost on every launch
-- after the first.
function GfxExtract.ensureAll()
	local areaCount = extractAreaIcons()
	local portraitCount = extractPortraits()
	local eggCount = extractEggHatchIcons()
	local total = areaCount + portraitCount + eggCount
	if total > 0 then
		console.log(string.format(
			"GfxExtract: extracted %d area icon(s), %d portrait(s), %d egg-hatch icon(s) from ROM",
			areaCount, portraitCount, eggCount))
	end
end
