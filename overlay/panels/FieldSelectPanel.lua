-- Field-select screen preview (Ruby/Sapphire choice only -- selectedField is
-- always 0/1 here, see the plan doc). Shows the same egg-pool grid/specials
-- column as normal play (no current area yet, so no travel diagram), plus
-- every area reachable on the highlighted field with its CD fraction, since
-- there's no "current board" to read wild-mon-table state from otherwise.
-- See .claude/plans/partitioned-wiggling-papert.md.

FieldSelectPanel = {}

local AREA_COLUMNS = 4
local AREA_CELL_GAP = 8
local AREA_CELL_W = NormalBoardPanel.PORTRAIT_W + 40 + AREA_CELL_GAP -- icon + beside-fraction + gap
local AREA_CELL_H = NormalBoardPanel.PORTRAIT_H + AREA_CELL_GAP

function FieldSelectPanel.draw(field)
	local panelHeight = SCREEN_HEIGHT + DOWN_PAD
	Draw.drawPanelBackground(GAME_X + SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight)
	-- Spans the full canvas width (SCREEN_WIDTH + RIGHT_PAD), not just
	-- SCREEN_WIDTH -- there's no travel diagram competing for the right
	-- flange's bottom on this screen, so the area list below gets that
	-- width too instead of being squeezed into the narrower below-screen
	-- strip alone. Same "draw past SCREEN_WIDTH into the next panel's
	-- background" precedent as the spawn grid's merged last row.
	Draw.drawPanelBackground(GAME_X, GAME_Y + SCREEN_HEIGHT, SCREEN_WIDTH + RIGHT_PAD, DOWN_PAD)

	local queueSet = NormalBoardPanel.readEvolvablePartySet()
	local eggPool = NormalBoardPanel.readEggPool(field, queueSet)
	local specials = NormalBoardPanel.readSpecials(field)
	local caught = NormalBoardPanel.readDexCaughtCount()
	NormalBoardPanel.drawEggAndSpecials(eggPool, specials, caught, false)

	local rowAddr = ADDR_AREA_ROULETTE_TABLE + field * AREA_ROULETTE_TABLE_SLOTS * 2
	local x, y = GAME_X + 4, GAME_Y + SCREEN_HEIGHT + 4
	for slot = 0, AREA_ROULETTE_TABLE_SLOTS - 1 do
		local area = Memory.readword(rowAddr + slot * 2)
		local col = slot % AREA_COLUMNS
		local row = math.floor(slot / AREA_COLUMNS)
		local cellX = x + col * AREA_CELL_W
		local cellY = y + row * AREA_CELL_H
		Draw.safeDrawImage(NormalBoardPanel.areaIconPath(area), cellX, cellY, NormalBoardPanel.PORTRAIT_W, NormalBoardPanel.PORTRAIT_H)
		local cdCount, cdTotal = NormalBoardPanel.readAreaCdProgress(area)
		Draw.drawCdStack(cellX, cellY, NormalBoardPanel.PORTRAIT_W, NormalBoardPanel.PORTRAIT_H, true, cdCount, cdTotal)
	end
end
