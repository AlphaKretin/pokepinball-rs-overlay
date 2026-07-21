"""
Right panel: egg-hatch grid (field-wide), dex-caught count + encounter-rate-up
marker, travel diagram (current area + 2 travel destinations w/ CD progress),
specials column (Pichu/Lati/Groudon-Kyogre/Rayquaza). Ported from
lua/Overlay.lua's drawEggPanel/drawTravelDiagram/drawSpecialCell (that
file's own comments explain the *why* behind each piece; this just
re-renders the same data with pygame instead of BizHawk's gui.* calls).

Run standalone (own window/process) with a ROM loaded and running in RAVBA.
"""

import math

import pygame

import ravba_data as data
import ravba_overlay_common as common
from ravba_memory import RavbaMemory, RavbaNotFound
from ravba_rom import RavbaRom
from ravba_state import GameState

EGG_GRID_COLUMNS = 5
EGG_CELL_GAP = 3
EGG_CELL_W = common.EGG_ICON_W + EGG_CELL_GAP
EGG_CELL_H = common.EGG_ICON_H + EGG_CELL_GAP
EGG_GRID_ROWS = math.ceil(25 / EGG_GRID_COLUMNS)
EGG_GRID_W = EGG_GRID_COLUMNS * EGG_CELL_W
EGG_GRID_H = EGG_GRID_ROWS * EGG_CELL_H

SPECIAL_CELL_GAP = 3
SPECIAL_CELL_H = common.PORTRAIT_H + SPECIAL_CELL_GAP
SPECIAL_COLUMN_GAP = 4

MARGIN = 4
TEXT_ROW_GAP = 6

ARROW_GAP = 14
TRAVEL_DIAGRAM_HEIGHT = common.PORTRAIT_H + ARROW_GAP + common.PORTRAIT_H
TRAVEL_DIAGRAM_WIDTH = 2 * common.PORTRAIT_W + 57
ARROW_START_INSET = common.PORTRAIT_W / 5

EGG_X, EGG_Y = MARGIN, MARGIN
SPECIALS_X = EGG_X + EGG_GRID_W + SPECIAL_COLUMN_GAP
SPECIALS_Y = EGG_Y

TEXT_LINE_HEIGHT = 20
DEX_TEXT_Y = EGG_Y + EGG_GRID_H + TEXT_ROW_GAP
TRAVEL_Y = DEX_TEXT_Y + TEXT_LINE_HEIGHT + TEXT_ROW_GAP

WINDOW_W = MARGIN + max(SPECIALS_X + common.PORTRAIT_W - EGG_X, TRAVEL_DIAGRAM_WIDTH) + MARGIN
WINDOW_H = TRAVEL_Y + TRAVEL_DIAGRAM_HEIGHT + MARGIN

POLL_INTERVAL_MS = 250


def round_px(v):
    return math.floor(v + 0.5)


def draw_arrow(screen, x1, y1, x2, y2, color):
    x1, y1, x2, y2 = round_px(x1), round_px(y1), round_px(x2), round_px(y2)
    pygame.draw.line(screen, color, (x1, y1), (x2, y2))
    dx, dy = x2 - x1, y2 - y1
    length = math.sqrt(dx * dx + dy * dy)
    if length == 0:
        return
    ux, uy = dx / length, dy / length
    px, py = -uy, ux
    head_len, head_width = 5, 3
    bx, by = x2 - ux * head_len, y2 - uy * head_len
    pygame.draw.line(screen, color, (x2, y2), (round_px(bx + px * head_width), round_px(by + py * head_width)))
    pygame.draw.line(screen, color, (x2, y2), (round_px(bx - px * head_width), round_px(by - py * head_width)))


def draw_cd_stack(screen, font, icon_x, icon_y, on_right, caught_count, total):
    caught_surf = font.render(str(caught_count), True, common.WHITE)
    total_surf = font.render(str(total), True, common.WHITE)
    stack_width = max(caught_surf.get_width(), total_surf.get_width())
    line_gap = 2
    stack_height = caught_surf.get_height() + line_gap * 2 + total_surf.get_height()
    block_x = (
        icon_x + common.PORTRAIT_W + 2
        if on_right
        else icon_x - 2 - stack_width
    )
    text_y = icon_y + (common.PORTRAIT_H - stack_height) / 2

    screen.blit(caught_surf, (block_x + (stack_width - caught_surf.get_width()) / 2, text_y))
    line_y = round_px(text_y + caught_surf.get_height() + line_gap)
    pygame.draw.line(screen, common.WHITE, (block_x, line_y), (block_x + stack_width, line_y))
    screen.blit(total_surf, (block_x + (stack_width - total_surf.get_width()) / 2, line_y + line_gap))


def draw_travel_diagram(screen, images, font, x, y, width, area_index, area_cd, area_total,
                         left_area, left_cd, left_total, right_area, right_cd, right_total):
    left_x = x
    right_x = x + width - common.PORTRAIT_W
    center_x = x + (width - common.PORTRAIT_W) / 2
    top_icon_y = y
    bottom_icon_y = top_icon_y + common.PORTRAIT_H + ARROW_GAP

    for path, pos in (
        (data.area_icon_path(left_area), (left_x, top_icon_y)),
        (data.area_icon_path(right_area), (right_x, top_icon_y)),
        (data.area_icon_path(area_index), (center_x, bottom_icon_y)),
    ):
        if path is None:
            continue
        img = images.get(path)
        if img is not None:
            screen.blit(img, pos)

    draw_cd_stack(screen, font, left_x, top_icon_y, True, left_cd, left_total)
    draw_cd_stack(screen, font, right_x, top_icon_y, False, right_cd, right_total)
    draw_cd_stack(screen, font, center_x, bottom_icon_y, True, area_cd, area_total)

    axis_x = round_px(center_x + common.PORTRAIT_W / 2)
    start_y = round_px(bottom_icon_y)
    end_y = round_px(top_icon_y + common.PORTRAIT_H)
    right_start_x = round_px(center_x + common.PORTRAIT_W - ARROW_START_INSET)
    right_end_x = round_px(right_x + common.PORTRAIT_W / 2)

    draw_arrow(screen, right_start_x, start_y, right_end_x, end_y, common.WHITE)
    draw_arrow(screen, 2 * axis_x - right_start_x, start_y, 2 * axis_x - right_end_x, end_y, common.WHITE)


def draw_egg_grid(screen, images, pool):
    for i, entry in enumerate(pool):
        if entry.name == "-":
            continue
        col = i % EGG_GRID_COLUMNS
        row = i // EGG_GRID_COLUMNS
        cell_x = EGG_X + col * EGG_CELL_W
        cell_y = EGG_Y + row * EGG_CELL_H
        common.draw_bordered_image(
            screen, images, data.egg_icon_path(entry.name), cell_x, cell_y,
            common.EGG_ICON_W, common.EGG_ICON_H, common.border_color_for(entry)
        )


def draw_specials_column(screen, images, specials):
    for i, entry in enumerate(specials):
        y = SPECIALS_Y + i * SPECIAL_CELL_H
        common.draw_bordered_image(
            screen, images, data.portrait_path(entry.name), SPECIALS_X, y,
            common.PORTRAIT_W, common.PORTRAIT_H, common.special_border_color_for(entry)
        )


def main():
    pygame.init()
    scale = common.parse_scale()
    screen, hwnd, surface = common.make_window(
        (WINDOW_W, WINDOW_H), "PPRS Overlay -- Right Panel", scale
    )
    images = common.ImageCache()
    font = pygame.font.SysFont("consolas", 16)
    dex_font = pygame.font.SysFont("consolas", 18)
    clock = pygame.time.Clock()

    mem = RavbaMemory()
    rom = RavbaRom()
    game = GameState(mem, rom)

    last_poll = 0
    snapshot = None
    status_text = "Connecting..."

    running = True
    while running:
        if not common.handle_common_events(pygame.event.get(), hwnd):
            running = False

        now = pygame.time.get_ticks()
        if now - last_poll >= POLL_INTERVAL_MS:
            last_poll = now
            try:
                mem.refresh()
                field = game.current_field()
                area = game.current_area()
                queue_set = game.read_evolvable_party_set()
                egg_pool = game.read_egg_pool(field, queue_set)
                specials = game.read_specials(field)
                rate_up = game.is_encounter_rate_up()
                area_cd, area_total = game.read_area_cd_progress(area)
                caught = game.read_dex_caught_count()
                left_area, right_area = game.read_travel_options()
                left_cd, left_total = game.read_area_cd_progress(left_area)
                right_cd, right_total = game.read_area_cd_progress(right_area)
                snapshot = dict(
                    egg_pool=egg_pool, specials=specials, rate_up=rate_up,
                    area=area, area_cd=area_cd, area_total=area_total,
                    left_area=left_area, left_cd=left_cd, left_total=left_total,
                    right_area=right_area, right_cd=right_cd, right_total=right_total,
                    caught=caught,
                )
                status_text = None
            except RavbaNotFound as e:
                status_text = str(e)

        surface.fill(common.BACKGROUND_COLOR)

        if status_text:
            surface.blit(font.render(status_text, True, (255, 120, 120)), (MARGIN, MARGIN))
        elif snapshot:
            draw_egg_grid(surface, images, snapshot["egg_pool"])
            draw_specials_column(surface, images, snapshot["specials"])

            dex_text = f"Dex caught: {snapshot['caught']}/{data.DEX_DISPLAY_TOTAL}"
            dex_surf = dex_font.render(dex_text, True, common.WHITE)
            surface.blit(dex_surf, (EGG_X, DEX_TEXT_Y))
            if snapshot["rate_up"]:
                common.draw_marker(
                    surface, EGG_X + dex_surf.get_width() + 6,
                    DEX_TEXT_Y + (dex_surf.get_height() - common.MARKER_SIZE) // 2,
                    common.RARE_MARKER_COLOR,
                )

            draw_travel_diagram(
                surface, images, font, EGG_X, TRAVEL_Y, TRAVEL_DIAGRAM_WIDTH,
                snapshot["area"], snapshot["area_cd"], snapshot["area_total"],
                snapshot["left_area"], snapshot["left_cd"], snapshot["left_total"],
                snapshot["right_area"], snapshot["right_cd"], snapshot["right_total"],
            )

        common.present(screen, surface, scale)
        clock.tick(30)

    mem.close()
    pygame.quit()


if __name__ == "__main__":
    main()
