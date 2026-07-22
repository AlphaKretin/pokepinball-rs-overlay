-- Shown on the main menu and its Options/Pokedex submenus, where the normal
-- board overlay's memory assumptions don't hold (no board is loaded) -- a
-- short blurb plus a full legend of every color/marker the normal-board and
-- bonus-stage panels use, so a first-time viewer can decode them without
-- external documentation. See .claude/plans/partitioned-wiggling-papert.md.

ExplainerPanel = {}

local SWATCH_SIZE = 8
local ROW_GAP = 4 -- extra vertical space between a swatch/label row and the next
local SECTION_GAP = 6 -- extra vertical space before a new section header

-- {color, label, outlineOnly}. outlineOnly draws a white-outlined swatch
-- instead of a solid fill, for BORDER_COLOR_UNCAUGHT, which is black and
-- would otherwise vanish against the panel's own black background -- same
-- reasoning as the comment on that constant in Draw.lua.
--
-- Labels kept short (panel is only ~RIGHT_PAD-4 px wide, room for maybe
-- 20-ish characters at this font) rather than fully spelling out each
-- state -- verify live in BizHawk and shorten further/wrap if anything
-- still overflows.
local BORDER_COLOR_ROWS = {
	{ Draw.BORDER_COLOR_UNCAUGHT, "Not caught", true },
	{ Draw.BORDER_COLOR_CAUGHT, "Caught" },
	{ Draw.BORDER_COLOR_PENDING_EVOLUTION, "Caught + evo queued" },
	{ Draw.BORDER_COLOR_LINE_CAUGHT, "Line complete" },
	{ Draw.BORDER_COLOR_ELIGIBLE, "Eligible (Pichu/Lati)" },
}

local MARKER_ROWS = {
	{ Draw.RARE_MARKER_COLOR, "Rare species" },
	{ Draw.TWO_EXCLUSIVE_MARKER_COLOR, "2-arrows exclusive" },
	{ Draw.THREE_EXCLUSIVE_MARKER_COLOR, "3-arrows exclusive" },
}

local function drawSwatchRow(x, y, color, label, outlineOnly)
	if outlineOnly then
		gui.drawRectangle(x, y, SWATCH_SIZE, SWATCH_SIZE, "white", nil)
	else
		gui.drawRectangle(x, y, SWATCH_SIZE, SWATCH_SIZE, color, color)
	end
	gui.drawText(x + SWATCH_SIZE + 6, y - 2, label, "white")
	return y + SWATCH_SIZE + ROW_GAP
end

function ExplainerPanel.draw()
	local panelHeight = SCREEN_HEIGHT + DOWN_PAD
	Draw.drawPanelBackground(GAME_X + SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight)
	Draw.drawPanelBackground(GAME_X, GAME_Y + SCREEN_HEIGHT, SCREEN_WIDTH, DOWN_PAD)

	local x, y = GAME_X + SCREEN_WIDTH + 4, 4
	gui.drawText(x, y, "Pokedex tracker overlay.", "white")
	y = y + LINE_HEIGHT
	gui.drawText(x, y, "Shows catch progress, spawn", "white")
	y = y + LINE_HEIGHT
	gui.drawText(x, y, "pools, and travel options", "white")
	y = y + LINE_HEIGHT
	gui.drawText(x, y, "during play.", "white")
	y = y + LINE_HEIGHT + SECTION_GAP

	gui.drawText(x, y, "Portrait/icon border:", "white")
	y = y + LINE_HEIGHT + ROW_GAP
	for _, row in ipairs(BORDER_COLOR_ROWS) do
		y = drawSwatchRow(x, y, row[1], row[2], row[3])
	end

	y = y + SECTION_GAP
	gui.drawText(x, y, "Corner marker:", "white")
	y = y + LINE_HEIGHT + ROW_GAP
	for _, row in ipairs(MARKER_ROWS) do
		y = drawSwatchRow(x, y, row[1], row[2])
	end

	y = y + SECTION_GAP
	-- Same gold as the rare-species marker (this flag raises rare-mon odds,
	-- same "worth prioritizing" meaning), not a dedicated color -- matches
	-- how it's drawn live next to the dex-caught count.
	y = drawSwatchRow(x, y, Draw.RARE_MARKER_COLOR, "Rare rate-up active")
end
