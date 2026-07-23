-- Per-bonus-stage progress: Kecleon, Dusclops, Kyogre, Groudon, Rayquaza,
-- Spheal. Shown whenever gMain.selectedField is a bonus field during actual
-- gameplay (mainState STATE_GAME_MAIN/STATE_GAME_IDLE) -- the normal board's
-- area/wild-mon reads don't apply to any of these boards.
-- See .claude/plans/partitioned-wiggling-papert.md for the RAM research
-- behind every address below (confirmed against reference/pokepinballrs
-- source, not yet live-verified in BizHawk).

BonusPanel = {}

-- PinballGame+0x013: generic per-board substate index, meaning is specific
-- to which board is loaded (include/global.h:136).
local ADDR_BOARD_STATE = PINBALL_GAME + 0x013

-- Dusclops boardState values (include/constants/board/dusclops_states.h).
local DUSCLOPS_BOARD_STATE_DUSKULL_PHASE = 1
local DUSCLOPS_BOARD_STATE_DUSCLOPS_PHASE = 3

-- Kecleon / Kyogre / Groudon / Rayquaza boardState "battle phase" value --
-- shared across kecleon_states.h and bonus_board.h's LegendaryBoardState,
-- both enum position 1.
local BATTLE_PHASE = 1

-- PinballGame+0x385 (s8): shared hit-count field, meaning depends on board/
-- boardState -- see the plan doc's RAM-facts section for the full
-- Kecleon/Dusclops/legendary breakdown.
local ADDR_BONUS_MODE_HIT_COUNT = PINBALL_GAME + 0x385
local KECLEON_HITS_REQUIRED = 10
-- DUSKULL_NEEDED_TO_PHASE_TRANSFER in source. Actual transition gate is a
-- couple kills fuzzier than this (see plan doc) -- displayed as the named
-- constant rather than false precision.
local DUSKULL_HITS_REQUIRED = 20
local DUSCLOPS_HITS_REQUIRED = 5

-- PinballGame+0x384 (s8): live RAM, 15 or 18 depending on completed-stage
-- count -- read directly rather than reimplementing that logic.
local ADDR_LEGENDARY_HITS_REQUIRED = PINBALL_GAME + 0x384

-- Devon Scope power-up (Kecleon board only): falling orb hits the ball ->
-- kecleonTargetActive=1, kecleonAnimTimer counts 0->600 (~10s at 60fps)
-- before auto-clearing and driving an actual screen overlay that reveals
-- Kecleon regardless of its own entity state. Confirmed distinct from the
-- unrelated hit-then-rise entity-state cycle (bossFrameTimer/
-- kecleonCamoStrength) -- see the plan doc.
local ADDR_KECLEON_TARGET_ACTIVE = PINBALL_GAME + 0x406
local ADDR_KECLEON_ANIM_TIMER = PINBALL_GAME + 0x408
local DEVON_SCOPE_DURATION_FRAMES = 600
local FRAMES_PER_SECOND = 60

-- PinballGame+0x52C (s8[2]): ix 0=spheal knockdowns (5,000,000 pts each),
-- 1=ball-through-hoop (1,000,000 pts each). spheal_process3.c:1665-1667.
local ADDR_SPHEAL_KNOCKDOWN_COUNT = PINBALL_GAME + 0x52C
local SPHEAL_POINTS_PER_KNOCKDOWN = 5000000
local SPHEAL_POINTS_PER_BALL = 1000000

local HEADER_Y = 4
local STAT_Y = HEADER_Y + LINE_HEIGHT + 8

local function drawHeader(text)
	local x = GAME_X + SCREEN_WIDTH + 4
	gui.drawText(x, HEADER_Y, text, "white")
	return x, STAT_Y
end

-- Text-fraction via Draw.drawCdStack at a bare anchor (iconW/iconH = 0, so
-- it positions relative to x directly) -- matches the travel diagram's
-- established beside-icon style even though there's no icon here, per
-- Luna's ask for visual consistency rather than a new bar-style element.
local function drawStat(x, y, label, count, total)
	gui.drawText(x, y, label, "white")
	Draw.drawCdStack(x + 90, y, 0, LINE_HEIGHT, true, count, total)
end

local function drawKecleon()
	local x, y = drawHeader("Kecleon")
	local boardState = Memory.readbyte(ADDR_BOARD_STATE)
	if boardState ~= BATTLE_PHASE then
		return
	end
	local hits = Memory.readbyte(ADDR_BONUS_MODE_HIT_COUNT)
	drawStat(x, y, "Hits", hits, KECLEON_HITS_REQUIRED)

	if Memory.readbyte(ADDR_KECLEON_TARGET_ACTIVE) ~= 0 then
		y = y + LINE_HEIGHT + 8
		local remainingFrames = DEVON_SCOPE_DURATION_FRAMES - Memory.readword(ADDR_KECLEON_ANIM_TIMER)
		local remainingSeconds = math.max(0, math.floor(remainingFrames / FRAMES_PER_SECOND))
		gui.drawText(x, y, "Devon Scope: " .. remainingSeconds .. "s", "white")
	end
end

local function drawDusclops()
	local x, y = drawHeader("Dusclops")
	local boardState = Memory.readbyte(ADDR_BOARD_STATE)
	local hits = Memory.readbyte(ADDR_BONUS_MODE_HIT_COUNT)
	if boardState == DUSCLOPS_BOARD_STATE_DUSKULL_PHASE then
		drawStat(x, y, "Duskull", hits, DUSKULL_HITS_REQUIRED)
	elseif boardState == DUSCLOPS_BOARD_STATE_DUSCLOPS_PHASE then
		drawStat(x, y, "Hits", hits, DUSCLOPS_HITS_REQUIRED)
	end
end

local function drawLegendary(name)
	local x, y = drawHeader(name)
	local boardState = Memory.readbyte(ADDR_BOARD_STATE)
	if boardState ~= BATTLE_PHASE then
		return
	end
	local hits = Memory.readbyte(ADDR_BONUS_MODE_HIT_COUNT)
	local required = Memory.readbyte(ADDR_LEGENDARY_HITS_REQUIRED)
	drawStat(x, y, "Hits", hits, required)
end

local function drawSpheal()
	local x, y = drawHeader("Spheal")
	local sphealCount = Memory.readbyte(ADDR_SPHEAL_KNOCKDOWN_COUNT)
	local ballCount = Memory.readbyte(ADDR_SPHEAL_KNOCKDOWN_COUNT + 1)
	gui.drawText(x, y, "Spheal knockdowns: " .. sphealCount, "white")
	y = y + LINE_HEIGHT + 4
	gui.drawText(x, y, "Ball-throughs: " .. ballCount, "white")
	y = y + LINE_HEIGHT + 8
	local score = sphealCount * SPHEAL_POINTS_PER_KNOCKDOWN + ballCount * SPHEAL_POINTS_PER_BALL
	gui.drawText(x, y, "Score: " .. score, "white")
end

function BonusPanel.draw(field)
	local panelHeight = SCREEN_HEIGHT + DOWN_PAD
	Draw.drawPanelBackground(GAME_X + SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight)
	Draw.drawPanelBackground(GAME_X, GAME_Y + SCREEN_HEIGHT, SCREEN_WIDTH, DOWN_PAD)

	if field == FIELD_KECLEON then
		drawKecleon()
	elseif field == FIELD_DUSCLOPS then
		drawDusclops()
	elseif field == FIELD_KYOGRE then
		drawLegendary("Kyogre")
	elseif field == FIELD_GROUDON then
		drawLegendary("Groudon")
	elseif field == FIELD_RAYQUAZA then
		drawLegendary("Rayquaza")
	elseif field == FIELD_SPHEAL then
		drawSpheal()
	end
end
