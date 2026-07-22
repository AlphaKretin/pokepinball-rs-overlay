-- Shared low-level drawing primitives used by every panel in overlay/panels/.
-- Split out of Overlay.lua once that file grew past one screen's worth of
-- panels -- see .claude/plans/partitioned-wiggling-papert.md.

Draw = {}

-- gui.drawImage errors out (aborting the whole overlay frame) on a missing
-- file rather than silently no-oping, same as pygame.image.load on the
-- Python side -- guard the same way: catch it, warn once via console.log,
-- and skip drawing that cell instead of taking the whole overlay down.
local warnedMissingImages = {}
function Draw.safeDrawImage(path, x, y, w, h)
	if not path then
		return
	end
	local ok, err = pcall(gui.drawImage, path, x, y, w, h)
	if not ok and not warnedMissingImages[path] then
		warnedMissingImages[path] = true
		console.log("Overlay: missing image " .. path .. " (" .. tostring(err) .. ")")
	end
end

-- gui.drawRectangle's width/height are corner-to-corner (the right/bottom
-- border line lands at x+width, y+height), not a pixel count the way
-- drawImage's w/h are -- so this only needs +1, not +2, to sit flush
-- against a portrait occupying columns/rows [x, x+w) / [y, y+h).
function Draw.drawPortraitBorder(x, y, w, h, color)
	gui.drawRectangle(x - 1, y - 1, w + 1, h + 1, color, nil)
end

-- A solid-black-filled panel background whose outline matches the fill --
-- BizHawk's gui.drawRectangle treats a nil/omitted outline as its own
-- default (white), not "no outline", so passing nil alone still draws a
-- border; matching the outline color to the fill is what actually
-- suppresses it. Confirmed live in BizHawk.
function Draw.drawPanelBackground(x, y, w, h)
	gui.drawRectangle(x, y, w, h, "black", "black")
end

-- A colored border around a caught species' portrait, instead of a
-- translucent dim overlay: dimming (even with a wide alpha gap between the
-- two states) read as barely-different at a glance against portraits with
-- such varied source brightness/color, and the most visible part of it
-- turned out to be the 1px undimmed edge left at the portrait's border --
-- which is the tell that a deliberate, saturated border reads far more
-- clearly than tinting the whole image ever did. Green once the whole
-- evolution line is caught (D, no longer worth pursuing); purple when the
-- line isn't finished but this species (or an evolution of it) is sitting
-- in the current evolvable-party queue, i.e. no more catching needed here,
-- just play Evolution Mode (C+ -- takes precedence over C but not D, since
-- the dex "caught" flag alone can't tell you whether *this session's* catch
-- is still queued to evolve); orange while just caught with nothing queued
-- (C); black (currently invisible against the panel's own black background,
-- but explicit so it'll show correctly if that background ever changes)
-- when not caught at all.
Draw.BORDER_COLOR_LINE_CAUGHT = 0xFF34C759
Draw.BORDER_COLOR_PENDING_EVOLUTION = 0xFFFF2D95
Draw.BORDER_COLOR_CAUGHT = 0xFFFF9500
Draw.BORDER_COLOR_UNCAUGHT = 0xFF000000

-- Shared by every panel's portrait/icon cells: D > C+ > C > uncaught.
-- entry needs {caught, lineCaught, pendingEvolution}.
function Draw.borderColorFor(entry)
	if not entry.caught then
		return Draw.BORDER_COLOR_UNCAUGHT
	end
	if entry.lineCaught then
		return Draw.BORDER_COLOR_LINE_CAUGHT
	end
	if entry.pendingEvolution then
		return Draw.BORDER_COLOR_PENDING_EVOLUTION
	end
	return Draw.BORDER_COLOR_CAUGHT
end

-- Specials-only tier, one step below "caught": a species with no evolution
-- target already lands on BORDER_COLOR_LINE_CAUGHT the moment it's caught
-- (isEvolutionLineCaught == isCaught for a species with no further
-- evolution), so this only adds a distinct color for "not caught yet, but
-- eligible to spawn/roll for". entry additionally needs {eligible}.
Draw.BORDER_COLOR_ELIGIBLE = 0xFFAF52DE

function Draw.specialBorderColorFor(entry)
	if not entry.caught and entry.eligible then
		return Draw.BORDER_COLOR_ELIGIBLE
	end
	return Draw.borderColorFor(entry)
end

-- Corner flags are plain solid-color squares, not icons or digits: at this
-- pixel budget, shapes/glyphs don't read cleanly -- an "ellipse" this small
-- rendered as a square anyway, and drawText numerals were illegible.
-- Colors are chosen so none of the three collide with each other.
Draw.MARKER_SIZE = 8
Draw.RARE_MARKER_COLOR = 0xFFFFD700 -- gold
Draw.TWO_EXCLUSIVE_MARKER_COLOR = 0xFF2E9BFF -- blue
Draw.THREE_EXCLUSIVE_MARKER_COLOR = 0xFFFF3B30 -- red

function Draw.drawMarker(x, y, color)
	gui.drawRectangle(x, y, Draw.MARKER_SIZE, Draw.MARKER_SIZE, "black", color)
end

function Draw.roundPx(v)
	return math.floor(v + 0.5)
end

-- Every coordinate is rounded to a pixel before gui.drawLine sees it, and
-- paired-arrow callers (see NormalBoardPanel's travel diagram) feed both
-- calls exact integer mirror images of each other rather than each
-- computing its own geometry independently -- both matter for the pair to
-- render as true reflections: at this resolution, two arrows with the
-- "same" geometry but computed separately can each round their floats to a
-- different pixel and end up visibly lopsided.
function Draw.drawArrow(x1, y1, x2, y2, color)
	x1, y1, x2, y2 = Draw.roundPx(x1), Draw.roundPx(y1), Draw.roundPx(x2), Draw.roundPx(y2)
	gui.drawLine(x1, y1, x2, y2, color)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len == 0 then
		return
	end
	local ux, uy = dx / len, dy / len
	local px, py = -uy, ux
	local headLen, headWidth = 5, 3
	local bx, by = x2 - ux * headLen, y2 - uy * headLen
	gui.drawLine(x2, y2, Draw.roundPx(bx + px * headWidth), Draw.roundPx(by + py * headWidth), color)
	gui.drawLine(x2, y2, Draw.roundPx(bx - px * headWidth), Draw.roundPx(by - py * headWidth), color)
end

-- Real measured metrics for gui.drawText's default font (Luna measured
-- these live in BizHawk, at 1x scale): a digit glyph's own visible pixels
-- are 9px tall, but they don't start right at the y passed to drawText --
-- there's a further 3px gap above the glyph before its visible pixels
-- begin. Confirmed via the fraction line: with the naive "row height =
-- glyph height" model, the numerator-to-line gap measured 2px live while
-- the line-to-denominator gap measured 5px, a 3px mismatch consistent with
-- exactly one glyph's worth of this offset applying to the denominator's
-- draw call but not being accounted for. This offset is a BizHawk
-- drawText-positioning detail, not padding baked into the font itself
-- (confirmed no such padding exists vertically, unlike the horizontal
-- monospacing case CD_CHAR_WIDTH accounts for).
local CD_GLYPH_HEIGHT = 9
local CD_GLYPH_Y_OFFSET = 3
-- Desired visible gap between a glyph's own pixels and the fraction line,
-- the same on both sides.
local CD_STACK_LINE_GAP = 2
-- Per-character advance for BizHawk's default gui.drawText font. Used to
-- size each fraction to its actual digit count (rather than a fixed
-- reserved box) so the gap to the icon comes out the same on both sides
-- regardless of whether it's showing "9/14" or "13/14" -- a fixed-width
-- reservation on one side only (an earlier version of this) made that
-- side's text overflow into the icon on wide numbers while the other
-- side's gap stayed loose. May need live tuning against the font's actual
-- advance.
-- Exposed (not local) since callers positioning their own text relative to
-- a drawCdStack-produced fraction (e.g. the rate-up marker beside the
-- dex-caught count) need the same per-character advance.
Draw.CD_CHAR_WIDTH = 10
local CD_CHAR_WIDTH = Draw.CD_CHAR_WIDTH
local CD_STACK_GAP = 2 -- gap between an icon's edge and its fraction

-- Caught/total for an icon-sized cell, as a tight fraction (count over
-- total, separated by a real drawn line rather than "--" text) beside the
-- icon instead of a caption above/below it. onRight places the fraction to
-- the icon's right (against its left edge), otherwise to its left (against
-- its right edge). Sized to the wider of the two numbers (via
-- CD_CHAR_WIDTH) rather than a fixed reserved box, so the narrower number
-- centers over the wider one and the gap to the icon comes out the same
-- regardless of digit count on either side.
--
-- iconW/iconH describe the icon-sized region this fraction sits beside --
-- pass the real icon's dimensions when one is drawn there, or an icon-sized
-- placeholder (iconW=0 is fine) to anchor the fraction at a bare x/y with
-- no icon at all (see BonusPanel, which has no per-stat icon to place).
function Draw.drawCdStack(iconX, iconY, iconW, iconH, onRight, cdCount, total)
	local caughtStr, totalStr = tostring(cdCount), tostring(total)
	local caughtWidth, totalWidth = #caughtStr * CD_CHAR_WIDTH, #totalStr * CD_CHAR_WIDTH
	local stackWidth = math.max(caughtWidth, totalWidth)
	local blockX = onRight and (iconX + iconW + CD_STACK_GAP) or (iconX - CD_STACK_GAP - stackWidth)

	-- Drawn-anchor-to-visible-bottom span (2 glyphs + 2 line gaps + one
	-- glyph's worth of CD_GLYPH_Y_OFFSET, see denomY below) -- used only to
	-- vertically center the whole fraction within the icon's height.
	local stackHeight = 2 * CD_GLYPH_HEIGHT + 2 * CD_STACK_LINE_GAP + CD_GLYPH_Y_OFFSET
	local textY = iconY + (iconH - stackHeight) / 2
	local lineY = Draw.roundPx(textY + CD_GLYPH_Y_OFFSET + CD_GLYPH_HEIGHT + CD_STACK_LINE_GAP)
	-- denomY is drawn CD_GLYPH_Y_OFFSET earlier than a naive "lineY + gap"
	-- would suggest, to cancel out that same offset applying again to the
	-- denominator's own draw call -- see CD_GLYPH_Y_OFFSET.
	local denomY = lineY + CD_STACK_LINE_GAP - CD_GLYPH_Y_OFFSET

	gui.drawText(blockX + (stackWidth - caughtWidth) / 2, textY, caughtStr, "white")
	gui.drawLine(blockX, lineY, blockX + stackWidth, lineY, "white")
	gui.drawText(blockX + (stackWidth - totalWidth) / 2, denomY, totalStr, "white")
end
