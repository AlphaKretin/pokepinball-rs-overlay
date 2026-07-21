"""
Shared window/rendering helpers for the two RAVBA overlay panel windows
(ravba_overlay_right.py, ravba_overlay_bottom.py). Each panel is its own
OS-level window -- pygame only supports one window per process, so each
runs as a separate process (see ravba_overlay_launcher.py) rather than
this being a single multi-window app.

Border-color scheme and marker colors are ported unchanged from
lua/Overlay.lua (same hex values, see that file's comments for the
caught/line-caught/pending-evolution/eligible tier reasoning) -- pygame
colors are (r, g, b) tuples rather than BizHawk's packed 0xAARRGGBB, so
these are just the same values re-expressed.
"""

import ctypes
import os
import sys

import pygame

IMAGES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lua", "images"
)

PORTRAIT_W, PORTRAIT_H = 48, 32
EGG_ICON_W, EGG_ICON_H = 24, 24

BORDER_COLOR_LINE_CAUGHT = (0x34, 0xC7, 0x59)
BORDER_COLOR_PENDING_EVOLUTION = (0xFF, 0x2D, 0x95)
BORDER_COLOR_CAUGHT = (0xFF, 0x95, 0x00)
BORDER_COLOR_UNCAUGHT = (0x40, 0x40, 0x40)
BORDER_COLOR_ELIGIBLE = (0xAF, 0x52, 0xDE)

RARE_MARKER_COLOR = (0xFF, 0xD7, 0x00)  # gold
TWO_EXCLUSIVE_MARKER_COLOR = (0x2E, 0x9B, 0xFF)  # blue
THREE_EXCLUSIVE_MARKER_COLOR = (0xFF, 0x3B, 0x30)  # red
MARKER_SIZE = 8

BACKGROUND_COLOR = (0, 0, 0)
WHITE = (255, 255, 255)


def border_color_for(entry):
    if not entry.caught:
        return BORDER_COLOR_UNCAUGHT
    if entry.line_caught:
        return BORDER_COLOR_LINE_CAUGHT
    if entry.pending_evolution:
        return BORDER_COLOR_PENDING_EVOLUTION
    return BORDER_COLOR_CAUGHT


def special_border_color_for(entry):
    if not entry.caught and entry.eligible:
        return BORDER_COLOR_ELIGIBLE
    return border_color_for(entry)


class ImageCache:
    def __init__(self):
        self._cache = {}

    def get(self, relative_path):
        img = self._cache.get(relative_path)
        if img is None:
            img = pygame.image.load(os.path.join(IMAGES_DIR, relative_path)).convert_alpha()
            self._cache[relative_path] = img
        return img


def draw_bordered_image(screen, images, image_path, x, y, w, h, color):
    screen.blit(images.get(image_path), (x, y))
    pygame.draw.rect(screen, color, pygame.Rect(x - 1, y - 1, w + 2, h + 2), width=1)


def draw_marker(screen, x, y, color):
    pygame.draw.rect(screen, (0, 0, 0), pygame.Rect(x, y, MARKER_SIZE, MARKER_SIZE))
    pygame.draw.rect(screen, color, pygame.Rect(x + 1, y + 1, MARKER_SIZE - 2, MARKER_SIZE - 2))


# -- Borderless, draggable, topmost window plumbing --------------------

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
    user32.ReleaseCapture()
    user32.SendMessageW(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0)


def parse_scale(default=1):
    """Integer window-scale factor, e.g. `--scale 2` or `--scale=2`.
    BizHawk's Lua overlay inherits the emulator's own zoom for free;
    these standalone windows have no emulator canvas to inherit a zoom
    from, so this is the equivalent knob."""
    argv = sys.argv[1:]
    for i, arg in enumerate(argv):
        if arg in ("--scale", "-s") and i + 1 < len(argv):
            try:
                return max(1, int(argv[i + 1]))
            except ValueError:
                pass
        if arg.startswith("--scale="):
            try:
                return max(1, int(arg.split("=", 1)[1]))
            except ValueError:
                pass
    return default


def make_window(native_size, title, scale=1):
    """Returns (screen, hwnd, native_surface). Draw onto `native_surface`
    at `native_size`, then call `present()` each frame -- it handles the
    integer upscale onto the actual (possibly larger) window."""
    pygame.display.set_caption(title)
    window_size = (native_size[0] * scale, native_size[1] * scale)
    screen = pygame.display.set_mode(window_size, pygame.NOFRAME)
    hwnd = pygame.display.get_wm_info()["window"]
    make_topmost(hwnd)
    native_surface = pygame.Surface(native_size)
    return screen, hwnd, native_surface


def present(screen, native_surface, scale):
    if scale == 1:
        screen.blit(native_surface, (0, 0))
    else:
        w, h = native_surface.get_size()
        # Plain (non-smooth) scale -- nearest-neighbor-style duplication
        # for integer factors, matching BizHawk's own crisp pixel zoom
        # rather than a blurred resize.
        scaled = pygame.transform.scale(native_surface, (w * scale, h * scale))
        screen.blit(scaled, (0, 0))
    pygame.display.flip()


def handle_common_events(events, hwnd):
    """Returns False if the window should close."""
    for event in events:
        if event.type == pygame.QUIT:
            return False
        if event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
            return False
        if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            start_native_drag(hwnd)
    return True
