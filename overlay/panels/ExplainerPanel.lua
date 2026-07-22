-- Shown on the main menu and its Options/Pokedex submenus, where the normal
-- board overlay's memory assumptions don't hold (no board is loaded) -- a
-- title block (bottom flange) plus a full legend of every color/marker the
-- normal-board and bonus-stage panels use (right flange), so a first-time
-- viewer can decode them without external documentation. See
-- .claude/plans/partitioned-wiggling-papert.md.
--
-- The title block lives in the bottom flange rather than the right flange
-- (moved there per .claude/plans/public-polish-deferred.md item 1) because
-- it's the wider of the two regions -- SCREEN_WIDTH (240px) vs. RIGHT_PAD's
-- content-driven minimum (~161px, see NormalBoardPanel.CONTENT_MIN_RIGHT_PAD)
-- -- so title-style centered lines have more room before wrapping.

ExplainerPanel = {}

local ROW_GAP = 4 -- extra vertical space between a grid row and the next
local TITLE_RULE_GAP = 4 -- space above/below the rule separating title from body blurb
local LEGEND_COLUMNS = 2
local LEGEND_LABEL_GAP = 2 -- vertical gap between a portrait's bottom edge and its label

-- Placeholder copy -- Luna is rewriting this once the layout shape is
-- confirmed live, so keep it short/generic rather than polishing wording
-- here. Centered in the bottom flange (SCREEN_WIDTH wide), so lines can run
-- longer than the old right-flange blurb could before wrapping.
local TITLE_LINES = {
	"Pinball RS Pokédex Tracker",
}
local BODY_LINES = {
	"LunaFlare, 2026",
	"Thanks to pret + UnopenedClosure",
	"",
	"Icon Legend on the right"
}

-- {kind, species, color, label, outlineOnly}. Real portrait examples
-- instead of solid-color swatches, per
-- .claude/plans/public-polish-deferred.md item 2 -- picks Luna already
-- made: Eligible->Latias, Rare->Nosepass, 2-arrows->Baltoy,
-- 3-arrows->Zangoose. The four border-color states (uncaught/caught/
-- pending-evo/line-caught) don't have a picked example yet -- Luvdisc is a
-- structural placeholder only, swap once Luna decides (needs to be
-- encounterable, not 2/3-arrow-exclusive, not in RARE_SPECIES -- see the
-- plan doc, that candidate list still needs generating).
--
-- kind = "border" draws the state border color (outlineOnly forces white
-- instead of the real, black-and-invisible-on-black BORDER_COLOR_UNCAUGHT,
-- for "Not caught" specifically); kind = "marker" draws the corner marker
-- instead, with no border -- these are demoing the marker specifically, not
-- a catch-state, so a border color would just be a distraction/imply a
-- state that doesn't apply.
--
-- Split into two explicit columns (not one flat list walked row/column-
-- major) so they can be semantically grouped per Luna, 2026-07-22: left is
-- plain catch-progress (uncaught -> caught -> evo queued -> line complete,
-- in state order), right is everything about "this one's worth extra
-- attention" (eligible-to-catch plus every corner marker).
local LEFT_COLUMN = {
	{ kind = "border", species = "Luvdisc", color = Draw.BORDER_COLOR_UNCAUGHT, label = "Uncaught", outlineOnly = true },
	{ kind = "border", species = "Luvdisc", color = Draw.BORDER_COLOR_CAUGHT, label = "Caught before" },
	{ kind = "border", species = "Luvdisc", color = Draw.BORDER_COLOR_PENDING_EVOLUTION, label = "Evolvable" },
	{ kind = "border", species = "Luvdisc", color = Draw.BORDER_COLOR_LINE_CAUGHT, label = "Completed" },
}
local RIGHT_COLUMN = {
	{ kind = "border", species = "Latias", color = Draw.BORDER_COLOR_ELIGIBLE, label = "Can spawn" },
	{ kind = "marker", species = "Baltoy", color = Draw.TWO_EXCLUSIVE_MARKER_COLOR, label = "GE only" },
	{ kind = "marker", species = "Zangoose", color = Draw.THREE_EXCLUSIVE_MARKER_COLOR, label = "GET only" },
	{ kind = "marker", species = "Nosepass", color = Draw.RARE_MARKER_COLOR, label = "Rare" },
}

-- Rate-up example: same Rayquaza portrait the marker actually renders on
-- live now (relocated there per item 3), so this is a real example like
-- every other row instead of a standalone swatch. Drawn specially (not as
-- a 5th row in both columns) -- portrait at the bottom of the left column,
-- caption beside it under the right column instead of below the portrait,
-- since a normal 5th row (portrait + caption stacked in one column) didn't
-- fit: reclaims one row's worth of height (LINE_HEIGHT + LEGEND_LABEL_GAP)
-- that stacking would've cost. See drawLegendGrid.
local RAYQUAZA_ENTRY = { species = "Rayquaza", color = Draw.RARE_MARKER_COLOR, label = "Lati up\nPichu down" }

-- gui.drawText's own multi-line handling doesn't work the way you'd expect
-- from horizalign="center": confirmed live, 2026-07-22 (Luna) -- it centers
-- the whole block's anchor using the *widest* line's width, then draws
-- every line left-flush against that shared edge, not individually
-- centered. So each line is drawn as its own separately-centered call
-- instead of handing gui.drawText a single string with embedded \n.
-- Vertical stacking uses native vertalign="middle" per line (not a
-- hand-computed offset -- that was the bug in the *previous* version of
-- this code, missed when horizontal centering was fixed the same way
-- earlier this session) rather than guessing at glyph height: each line's
-- own row-center is spaced LINE_HEIGHT apart around centerY, so the whole
-- block ends up centered on centerY without needing to know font metrics
-- at all.
local function drawTextBlockCentered(x, centerY, text, color)
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	local firstY = centerY - (#lines - 1) * LINE_HEIGHT / 2
	for i, line in ipairs(lines) do
		Draw.drawTextCentered(x, firstY + (i - 1) * LINE_HEIGHT, line, color, "middle")
	end
end

-- Labels centered under their portrait's own width, not left-aligned --
-- per Luna, 2026-07-22, alongside centering the columns themselves within
-- the available width (see drawLegendGrid). Still expected to overflow a
-- narrow column on longer labels (e.g. "Caught + evo queued") -- Luna is
-- rewriting these once she's seen the arrangement live, not fixed here.
local function drawLegendCell(x, y, entry)
	local pw, ph = NormalBoardPanel.PORTRAIT_W, NormalBoardPanel.PORTRAIT_H
	Draw.safeDrawImage(NormalBoardPanel.portraitPath(entry.species), x, y, pw, ph)
	if entry.kind == "marker" then
		Draw.drawMarker(x - 2, y - 2, entry.color)
	else
		Draw.drawPortraitBorder(x, y, pw, ph, entry.outlineOnly and "white" or entry.color)
	end
	Draw.drawTextCentered(x + pw / 2, y + ph + LEGEND_LABEL_GAP, entry.label)
end

-- Two fixed columns (LEFT_COLUMN/RIGHT_COLUMN) plus the special Rayquaza
-- row at the bottom. Leftover width (beyond the two portraits' own
-- LEGEND_COLUMNS * pw) is split three ways -- left margin, the gap between
-- columns, right margin -- rather than dumped entirely into the gap, so
-- the grid reads as centered within the flange instead of hugging its left
-- edge, per Luna, 2026-07-22.
local function drawLegendGrid(x, y, width)
	local pw, ph = NormalBoardPanel.PORTRAIT_W, NormalBoardPanel.PORTRAIT_H
	local slack = (width - LEGEND_COLUMNS * pw) / (LEGEND_COLUMNS + 1)
	local col0X = x + slack
	local col1X = col0X + pw + slack
	local cellH = ph + LEGEND_LABEL_GAP + LINE_HEIGHT + ROW_GAP

	for i, entry in ipairs(LEFT_COLUMN) do
		drawLegendCell(col0X, y + (i - 1) * cellH, entry)
	end
	for i, entry in ipairs(RIGHT_COLUMN) do
		drawLegendCell(col1X, y + (i - 1) * cellH, entry)
	end

	local rayquazaY = y + #LEFT_COLUMN * cellH
	Draw.safeDrawImage(NormalBoardPanel.portraitPath(RAYQUAZA_ENTRY.species), col0X, rayquazaY, pw, ph)
	Draw.drawMarker(col0X - 2, rayquazaY - 2, RAYQUAZA_ENTRY.color)
	drawTextBlockCentered(col1X + pw / 2, rayquazaY + ph / 2, RAYQUAZA_ENTRY.label)
end

-- Centers a line of text within the bottom flange's full SCREEN_WIDTH.
local function centerText(y, text, color)
	Draw.drawTextCentered(GAME_X + SCREEN_WIDTH / 2, y, text, color)
	return y + LINE_HEIGHT
end

function ExplainerPanel.draw()
	local panelHeight = SCREEN_HEIGHT + DOWN_PAD
	Draw.drawPanelBackground(GAME_X + SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight)
	Draw.drawPanelBackground(GAME_X, GAME_Y + SCREEN_HEIGHT, SCREEN_WIDTH, DOWN_PAD)

	-- Bottom flange: title block, centered -- see the file-header comment
	-- for why this content lives here instead of the right flange now.
	local by = GAME_Y + SCREEN_HEIGHT + PANEL_TOP_MARGIN
	for _, line in ipairs(TITLE_LINES) do
		by = centerText(by, line)
	end
	by = by + TITLE_RULE_GAP
	gui.drawLine(GAME_X + 40, by, GAME_X + SCREEN_WIDTH - 40, by, "white")
	by = by + TITLE_RULE_GAP
	for _, line in ipairs(BODY_LINES) do
		by = centerText(by, line)
	end

	-- Right flange: legend only now that the title block has moved below.
	-- No section headers ("Portrait/icon border:" / "Corner marker:") --
	-- cut per Luna, 2026-07-22: the portrait examples should read as
	-- self-explanatory once real species are picked, and the headers cost
	-- more vertical room than an already-tight grid can spare.
	-- No pre-added left margin here (unlike every other panel's "+4") --
	-- drawLegendGrid distributes the whole RIGHT_PAD width itself, margins
	-- included, so it can center the two columns rather than stacking its
	-- own margin on top of a fixed one.
	drawLegendGrid(GAME_X + SCREEN_WIDTH, 4, RIGHT_PAD)
end
