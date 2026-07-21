"""
Read-only access to GBA EWRAM inside a running RAVBA
(RetroAchievements VisualBoyAdvance-M) process, for the external overlay.

Only OpenProcess + ReadProcessMemory are used -- nothing is ever written to
the target process. This keeps the tool firmly on the "memory reader" side
of RetroAchievements hardcore mode's rules, not the "memory editor" side.

g_workRAM (EWRAM, 256KB) is a `calloc`'d global in RAVBA/VBA-M, so its
buffer address changes every launch/reset. The pointer *slot* holding that
address sits at a fixed offset from the main module's base for a given
RAVBA build -- see python/find_ravba_ram_offsets.py for how that offset was
discovered (WORKRAM_PTR_RVA below). If you update RAVBA, re-run that
discovery script and update the constant.
"""

import ctypes
import struct
from ctypes import wintypes

PROCESS_NAME = "RAVisualBoyAdvance-M.exe"

# Discovered via python/find_ravba_ram_offsets.py against RAVBA 1.2 (the
# build in C:\Users\lunad\Documents\Games\Emulation\GBA\RAVBA-x64). Re-run
# that script if RAVBA is updated and this stops resolving.
WORKRAM_PTR_RVA = 0x1186BF0

EWRAM_BASE = 0x02000000
SIZE_WRAM = 0x40000

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
TH32CS_SNAPPROCESS = 0x00000002
TH32CS_SNAPMODULE = 0x00000008
TH32CS_SNAPMODULE32 = 0x00000010

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)


class PROCESSENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD),
        ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
        ("th32ModuleID", wintypes.DWORD),
        ("cntThreads", wintypes.DWORD),
        ("th32ParentProcessID", wintypes.DWORD),
        ("pcPriClassBase", ctypes.c_long),
        ("dwFlags", wintypes.DWORD),
        ("szExeFile", ctypes.c_char * 260),
    ]


class MODULEENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("th32ModuleID", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD),
        ("GlblcntUsage", wintypes.DWORD),
        ("ProccntUsage", wintypes.DWORD),
        ("modBaseAddr", ctypes.POINTER(ctypes.c_byte)),
        ("modBaseSize", wintypes.DWORD),
        ("hModule", wintypes.HMODULE),
        ("szModule", ctypes.c_char * 256),
        ("szExePath", ctypes.c_char * 260),
    ]


class RavbaNotFound(Exception):
    pass


def _find_pid(name):
    snap = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == -1:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = PROCESSENTRY32()
        entry.dwSize = ctypes.sizeof(PROCESSENTRY32)
        found = kernel32.Process32First(snap, ctypes.byref(entry))
        while found:
            if entry.szExeFile.decode(errors="ignore").lower() == name.lower():
                return entry.th32ProcessID
            found = kernel32.Process32Next(snap, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snap)
    return None


def _find_main_module(pid):
    snap = kernel32.CreateToolhelp32Snapshot(
        TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid
    )
    if snap == -1:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = MODULEENTRY32()
        entry.dwSize = ctypes.sizeof(MODULEENTRY32)
        found = kernel32.Module32First(snap, ctypes.byref(entry))
        if found:
            base = ctypes.cast(entry.modBaseAddr, ctypes.c_void_p).value
            return base
    finally:
        kernel32.CloseHandle(snap)
    return None


class RavbaMemory:
    """Attaches to a running RAVBA process and reads GBA EWRAM by absolute
    GBA address (e.g. 0x0200B0C0).

    Call `refresh()` once per poll cycle (NOT once per read -- attaching
    involves a CreateToolhelp32Snapshot process-list enumeration, which is
    too slow to redo on every single byte/word read; doing so was
    previously making the overlay windows laggy and unresponsive to drag).
    `refresh()` only re-enumerates processes the first time or after a
    failed read invalidates the cached handle; `read_ewram`/`read_u8`/etc.
    just reuse whatever `refresh()` last resolved.
    """

    def __init__(self):
        self._h_process = None
        self._module_base = None
        self._pid = None
        self._workram_addr = None

    def _ensure_attached(self):
        if self._h_process is not None:
            return
        pid = _find_pid(PROCESS_NAME)
        if pid is None:
            raise RavbaNotFound(f"{PROCESS_NAME} is not running")
        module_base = _find_main_module(pid)
        if module_base is None:
            raise RavbaNotFound("could not read RAVBA's main module base")
        h_process = kernel32.OpenProcess(
            PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid
        )
        if not h_process:
            raise ctypes.WinError(ctypes.get_last_error())
        self._pid = pid
        self._module_base = module_base
        self._h_process = h_process

    def _detach(self):
        if self._h_process:
            kernel32.CloseHandle(self._h_process)
        self._h_process = None
        self._module_base = None
        self._pid = None
        self._workram_addr = None

    def _read_raw(self, address, size):
        buf = ctypes.create_string_buffer(size)
        bytes_read = ctypes.c_size_t(0)
        ok = kernel32.ReadProcessMemory(
            self._h_process,
            ctypes.c_void_p(address),
            buf,
            size,
            ctypes.byref(bytes_read),
        )
        if not ok or bytes_read.value != size:
            return None
        return buf.raw

    def refresh(self):
        """Re-resolve the process handle (if needed) and the current
        g_workRAM buffer address. Call this once per poll cycle."""
        self._ensure_attached()
        ptr_bytes = self._read_raw(self._module_base + WORKRAM_PTR_RVA, 8)
        if ptr_bytes is None:
            # Handle may be stale (process exited/restarted) -- reconnect
            # once and retry before giving up.
            self._detach()
            self._ensure_attached()
            ptr_bytes = self._read_raw(self._module_base + WORKRAM_PTR_RVA, 8)
            if ptr_bytes is None:
                raise RavbaNotFound("failed to read g_workRAM pointer slot")
        addr = struct.unpack("<Q", ptr_bytes)[0]
        if addr == 0:
            self._workram_addr = None
            raise RavbaNotFound("g_workRAM is null -- no ROM loaded yet")
        self._workram_addr = addr

    def read_ewram(self, gba_addr, size):
        """Read `size` bytes from GBA EWRAM starting at absolute GBA
        address `gba_addr` (must be in 0x02000000-0x0203FFFF). Requires a
        prior successful `refresh()` call this poll cycle."""
        if not (EWRAM_BASE <= gba_addr < EWRAM_BASE + SIZE_WRAM):
            raise ValueError(f"0x{gba_addr:X} is not an EWRAM address")
        offset = gba_addr - EWRAM_BASE
        if offset + size > SIZE_WRAM:
            raise ValueError("read runs past the end of EWRAM")
        if self._workram_addr is None:
            raise RavbaNotFound("not connected -- call refresh() first")
        data = self._read_raw(self._workram_addr + offset, size)
        if data is None:
            raise RavbaNotFound("EWRAM read failed -- process may have exited")
        return data

    def read_u8(self, gba_addr):
        return self.read_ewram(gba_addr, 1)[0]

    def read_u16(self, gba_addr):
        return struct.unpack("<H", self.read_ewram(gba_addr, 2))[0]

    def read_u32(self, gba_addr):
        return struct.unpack("<I", self.read_ewram(gba_addr, 4))[0]

    def close(self):
        self._detach()
