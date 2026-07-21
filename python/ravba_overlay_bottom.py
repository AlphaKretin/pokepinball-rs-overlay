"""
Bottom panel: current-area spawn-pool grid (portraits + caught/line-caught/
pending-evolution border, rare/arrow-exclusive corner markers). Ported from
lua/Overlay.lua's drawSpawnPanel/spawnGridCell/drawPortraitCell.

Run standalone (own window/process) with a ROM loaded and running in RAVBA.
"""

import math

import pygame

import ravba_data as data
import ravba_overlay_common as common
from ravba_memory import RavbaMemory, RavbaNotFound
from ravba_rom import RavbaRom
from ravba_state import GameState

GRID_COLUMNS = 4
CELL_GAP = 3
CELL_W = common.PORTRAIT_W + CELL_GAP
CELL_H = common.PORTRAIT_H + CELL_GAP
GRID_MAX_ROWS = 2  # see spawn_grid_cell -- the 9-case widens its last row instead of a 3rd

MARGIN = 4
POLL_INTERVAL_MS = 250

# Worst case (the 9-species "widen last row" case) is 5 columns wide.
WINDOW_W = MARGIN + 5 * CELL_W + MARGIN
WINDOW_H = MARGIN + GRID_MAX_ROWS * CELL_H + MARGIN


def spawn_grid_cell(i, pool_size, columns):
    """Row/col for spawn-pool grid cell i (0-indexed) of a pool_size-entry
    pool at the given column count. If the last row would hold exactly one
    lonely portrait, that portrait is merged into the previous row instead
    (one row of columns+1 beats reserving a whole extra row for one cell).
    """
    rows = math.ceil(pool_size / columns)
    last_row_start = (rows - 1) * columns
    if pool_size - last_row_start == 1 and rows > 1:
        rows -= 1
        last_row_start -= columns
    if i >= last_row_start:
        return rows - 1, i - last_row_start
    return i // columns, i % columns


def draw_spawn_grid(screen, images, pool):
    for i, entry in enumerate(pool):
        row, col = spawn_grid_cell(i, len(pool), GRID_COLUMNS)
        cell_x = MARGIN + col * CELL_W
        cell_y = MARGIN + row * CELL_H
        common.draw_bordered_image(
            screen, images, data.portrait_path(entry.name), cell_x, cell_y,
            common.PORTRAIT_W, common.PORTRAIT_H, common.border_color_for(entry)
        )

        exclusive_color = None
        if entry.exclusive == "2":
            exclusive_color = common.TWO_EXCLUSIVE_MARKER_COLOR
        elif entry.exclusive == "3":
            exclusive_color = common.THREE_EXCLUSIVE_MARKER_COLOR

        if entry.rare and exclusive_color:
            common.draw_marker(screen, cell_x - 2, cell_y - 2, common.RARE_MARKER_COLOR)
            common.draw_marker(screen, cell_x + common.PORTRAIT_W - common.MARKER_SIZE + 2, cell_y - 2, exclusive_color)
        elif entry.rare:
            common.draw_marker(screen, cell_x - 2, cell_y - 2, common.RARE_MARKER_COLOR)
        elif exclusive_color:
            common.draw_marker(screen, cell_x - 2, cell_y - 2, exclusive_color)


def main():
    pygame.init()
    scale = common.parse_scale()
    screen, hwnd, surface = common.make_window(
        (WINDOW_W, WINDOW_H), "PPRS Overlay -- Spawn Pool", scale
    )
    images = common.ImageCache()
    font = pygame.font.SysFont("consolas", 16)
    clock = pygame.time.Clock()

    mem = RavbaMemory()
    rom = RavbaRom()
    game = GameState(mem, rom)

    last_poll = 0
    pool = None
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
                area = game.current_area()
                queue_set = game.read_evolvable_party_set()
                pool = game.read_spawn_pool(area, queue_set)
                status_text = None
            except RavbaNotFound as e:
                status_text = str(e)

        surface.fill(common.BACKGROUND_COLOR)
        if status_text:
            surface.blit(font.render(status_text, True, (255, 120, 120)), (MARGIN, MARGIN))
        elif pool is not None:
            draw_spawn_grid(surface, images, pool)

        common.present(screen, surface, scale)
        clock.tick(30)

    mem.close()
    pygame.quit()


if __name__ == "__main__":
    main()
