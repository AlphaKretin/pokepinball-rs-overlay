"""
MVP standalone overlay: a small always-on-top floating window showing the
live Pokedex-caught count, read out of a running RAVBA process via
ravba_memory.py. Meant to sit next to the RAVBA window (position it
yourself -- this doesn't try to dock to or mirror the emulator window).

This is a proof-of-concept for the read-only external-overlay approach
(see conversation/plan for the full feature set to port from lua/Overlay.lua
next: egg grid, travel diagram, spawn panel, specials column). Once this is
confirmed working live against RAVBA, those panels get layered in.

Run with a ROM loaded and running in RAVBA; the window will show
"RAVBA not found" / "no ROM loaded" text until it can read EWRAM.
"""

import ctypes

import pygame

from ravba_memory import RavbaMemory, RavbaNotFound

GMAIN = 0x0200B0C0
ADDR_POKEDEX_FLAGS = GMAIN + 0x74
POKEDEX_FLAG_CAUGHT = 4
NUM_SPECIES = 205
NUM_EREADER_ONLY_SPECIES = 4
DEX_DISPLAY_TOTAL = NUM_SPECIES - NUM_EREADER_ONLY_SPECIES

POLL_INTERVAL_MS = 250
WINDOW_SIZE = (280, 60)

HWND_TOPMOST = -1
SWP_NOMOVE = 0x0002
SWP_NOSIZE = 0x0001

WM_SYSCOMMAND = 0x0112
SC_MOVE = 0xF010
HTCAPTION = 2

user32 = ctypes.windll.user32


def make_topmost(hwnd):
    user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE)


def start_native_drag(hwnd):
    # Hands the drag off to Windows' own move loop (same mechanism a normal
    # title bar uses) instead of us polling GetCursorPos/SetWindowPos every
    # frame -- the latter is visibly jittery since it's bottlenecked by our
    # render loop's frame rate rather than driven by the OS directly.
    user32.ReleaseCapture()
    user32.SendMessageW(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0)


def read_dex_caught_count(ram: RavbaMemory):
    flags = ram.read_ewram(ADDR_POKEDEX_FLAGS, NUM_SPECIES)
    return sum(1 for b in flags if b == POKEDEX_FLAG_CAUGHT)


def main():
    pygame.init()
    pygame.display.set_caption("PPRS Overlay (MVP)")
    screen = pygame.display.set_mode(WINDOW_SIZE, pygame.NOFRAME)

    hwnd = pygame.display.get_wm_info()["window"]
    make_topmost(hwnd)

    font = pygame.font.SysFont("consolas", 22)
    clock = pygame.time.Clock()

    ram = RavbaMemory()
    last_poll = 0
    status_text = "Connecting..."
    status_color = (200, 200, 200)

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
                running = False
            elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                start_native_drag(hwnd)

        now = pygame.time.get_ticks()
        if now - last_poll >= POLL_INTERVAL_MS:
            last_poll = now
            try:
                ram.refresh()
                caught = read_dex_caught_count(ram)
                status_text = f"Dex caught: {caught}/{DEX_DISPLAY_TOTAL}"
                status_color = (255, 255, 255)
            except RavbaNotFound as e:
                status_text = str(e)
                status_color = (255, 120, 120)

        screen.fill((20, 20, 20))
        surface = font.render(status_text, True, status_color)
        screen.blit(surface, (12, WINDOW_SIZE[1] // 2 - surface.get_height() // 2))
        pygame.display.flip()
        clock.tick(30)

    ram.close()
    pygame.quit()


if __name__ == "__main__":
    main()
