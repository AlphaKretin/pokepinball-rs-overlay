-- Pokedex-completion overlay for Pokemon Pinball: Ruby & Sapphire, for use
-- with BizHawk's mGBA core. See docs/memory-map.md for the addresses used
-- here, and overlay/panels/ for the actual panel content -- this file is
-- just the entry point: shared globals, the canvas-size joint-solve, and
-- the top-level state dispatch. See .claude/plans/partitioned-wiggling-papert.md
-- for how/why this got split up.
--
-- Canvas wraps the native 240x160 GBA screen with a right panel (full
-- canvas height -- takes the bottom-right corner) and a region below the
-- screen, only as wide as the screen itself (unless a panel deliberately
-- borrows the right panel's idle width, see FieldSelectPanel). Only shows
-- info that isn't already visible in the game's own UI.
--
-- IMPORTANT: gui.draw* coordinates are relative to the *padded canvas's*
-- own top-left (0,0), not the game screen's -- client.SetGameExtraPadding
-- shifts the emulated screen itself right/down by (LEFT_PAD, TOP_PAD)
-- within that canvas, it doesn't move the drawing origin. Confirmed live in
-- BizHawk (LEFT_PAD used to be assumed screen-relative -- i.e. drawing the
-- left panel at negative x, and the right panel/bottom bar at x=0/
-- x=SCREEN_WIDTH -- which put the left panel entirely off-canvas and the
-- right panel drawing over the middle of the shifted game screen instead of
-- the actual padding area). GAME_X below is the correction: every
-- game-relative draw call needs to add it now that LEFT_PAD is nonzero.
--
-- Every file dofile'd below shares this same global environment (BizHawk
-- Lua has no per-file module scope) -- that's how Memory/Data/GfxExtract
-- already worked, and why the constants defined in this section (GMAIN,
-- PINBALL_GAME, SCREEN_WIDTH, GAME_X, RIGHT_PAD, etc.) are plain globals
-- rather than locals: every panel file dofile'd afterward needs to read
-- them, either at its own load time (sizing constants) or at draw-call time
-- (RIGHT_PAD/DOWN_PAD, only known once every panel's content-min has been
-- collected).

dofile("Memory.lua")
dofile("Data.lua")
dofile("GfxExtract.lua")

-- Self-extracts area/portrait/egg-hatch icons straight from the loaded ROM
-- on first launch (no-op on every launch after) -- see GfxExtract.lua. Must
-- run before any gui.drawImage call below expects these files to exist.
GfxExtract.ensureAll()

GMAIN = 0x0200B0C0
PINBALL_GAME = 0x02000000

-- gMain.mainState -- include/constants/global.h. Tells menu vs. gameplay
-- vs. which menu screen; not yet live-verified in BizHawk, see the plan
-- doc's RAM-facts section.
ADDR_MAIN_STATE = GMAIN + 0x02
STATE_INTRO = 0
STATE_TITLE = 1
STATE_GAME_MAIN = 2
STATE_GAME_IDLE = 3
STATE_OPTIONS = 4
STATE_POKEDEX = 5
STATE_SAVE_ERASE = 6
STATE_EREADER = 7
STATE_SCORES_MAIN = 8
STATE_SCORES_IDLE = 9
STATE_FIELD_SELECT = 10
STATE_BONUS_FIELD_SELECT = 11

-- gMain.selectedField -- include/constants/fields.h. Confirmed the
-- authoritative board-type dispatch key in
-- src/all_board_pinball_game_main.c, and (src/field_select.c:280) that it
-- tracks the *currently highlighted* field every frame during
-- STATE_FIELD_SELECT, not just on confirm.
ADDR_SELECTED_FIELD = GMAIN + 0x04
FIELD_RUBY = 0
FIELD_SAPPHIRE = 1
MAIN_FIELD_COUNT = 2
FIELD_DUSCLOPS = 2
FIELD_KECLEON = 3
FIELD_KYOGRE = 4
FIELD_GROUDON = 5
FIELD_RAYQUAZA = 6
FIELD_SPHEAL = 7

-- gAreaRouletteTable: ROM data, data/rom_1.s:11, abs 0x08055A68. Shape
-- [2 fields][7 slots] of s16 AREA_* values -- slots 0-5 are the normal
-- travel ring per field. Slot 6 is Ruin: reachable both via the e-reader
-- bonus card (as a roulette-spin starting area) AND, unconditionally, as
-- every 6th travel since the last Ruin visit -- main_board_travel_mode.c:147-163.
-- Shared by NormalBoardPanel (current area's travel options) and
-- FieldSelectPanel (every area on the highlighted field).
ADDR_AREA_ROULETTE_TABLE = 0x08055A68
AREA_ROULETTE_TABLE_SLOTS = 7
AREA_ROULETTE_RUIN_SLOT = 6

SCREEN_WIDTH = 240
SCREEN_HEIGHT = 160
LINE_HEIGHT = 14
PANEL_TOP_MARGIN, PANEL_BOTTOM_MARGIN = 4, 4

local TARGET_ASPECT_W, TARGET_ASPECT_H = 16, 9

-- No panel has needed top padding so far -- named rather than inlined as a
-- literal 0 in SetGameExtraPadding/GAME_Y below since that's very much not
-- expected to stay true (a top flange is already under consideration).
local UP_PAD = 0

-- GAME_X is 0 now that there's no left flange, but kept named (not inlined)
-- since every game-relative draw call already expects to add it.
GAME_X, GAME_Y = 0, UP_PAD

dofile("Draw.lua")
dofile("panels/NormalBoardPanel.lua")
dofile("panels/ExplainerPanel.lua")
dofile("panels/BonusPanel.lua")
dofile("panels/FieldSelectPanel.lua")

-- The right flange and the below-screen region don't share one height-max
-- the way two side flanges would -- below-screen's height is additive with
-- the screen's own height instead, so the two candidates for minCanvasHeight
-- are "right flange's own corner-to-corner height" and "screen height +
-- below-screen content's height stacked beneath it". Only NormalBoardPanel
-- contributes content-min terms -- every other panel (Explainer/Bonus/
-- FieldSelect) was designed to fit within the budget that drives, see the
-- plan doc.
local minCanvasHeight = math.max(NormalBoardPanel.CONTENT_MIN_RIGHT_PANEL_HEIGHT,
	SCREEN_HEIGHT + NormalBoardPanel.CONTENT_MIN_BELOW_SCREEN_HEIGHT)
local minCanvasWidth = SCREEN_WIDTH + NormalBoardPanel.CONTENT_MIN_RIGHT_PAD
local widthForRatio = math.ceil(minCanvasHeight * TARGET_ASPECT_W / TARGET_ASPECT_H)
local finalWidth = math.max(minCanvasWidth, widthForRatio)
local finalHeight = math.ceil(finalWidth * TARGET_ASPECT_H / TARGET_ASPECT_W)

-- Only one side flange now, so any ratio-driven width slack goes entirely
-- to RIGHT_PAD -- no split needed.
RIGHT_PAD = NormalBoardPanel.CONTENT_MIN_RIGHT_PAD + (finalWidth - minCanvasWidth)
DOWN_PAD = finalHeight - SCREEN_HEIGHT

client.SetGameExtraPadding(0, UP_PAD, RIGHT_PAD, DOWN_PAD)

local function drawOverlay()
	local mainState = Memory.readbyte(ADDR_MAIN_STATE)
	local selectedField = Memory.readbyte(ADDR_SELECTED_FIELD)

	if mainState == STATE_INTRO or mainState == STATE_TITLE or mainState == STATE_OPTIONS or mainState == STATE_POKEDEX then
		-- STATE_INTRO (the pre-title-screen splash) gets the same explainer
		-- as the title menu itself -- no reason to sit blank there when
		-- there's nothing state-specific it needs instead.
		ExplainerPanel.draw()
	elseif mainState == STATE_GAME_MAIN or mainState == STATE_GAME_IDLE then
		if selectedField < MAIN_FIELD_COUNT then
			NormalBoardPanel.draw()
		else
			BonusPanel.draw(selectedField)
		end
	elseif mainState == STATE_FIELD_SELECT then
		FieldSelectPanel.draw(selectedField)
	else
		-- STATE_SAVE_ERASE, STATE_EREADER, STATE_SCORES_MAIN/IDLE,
		-- STATE_BONUS_FIELD_SELECT: no memory here means anything the other
		-- panels could sensibly read, so just blank the canvas rather than
		-- showing chaotic content.
		local panelHeight = SCREEN_HEIGHT + DOWN_PAD
		Draw.drawPanelBackground(GAME_X + SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight)
		Draw.drawPanelBackground(GAME_X, GAME_Y + SCREEN_HEIGHT, SCREEN_WIDTH, DOWN_PAD)
	end
end

while true do
	drawOverlay()
	emu.frameadvance()
end
