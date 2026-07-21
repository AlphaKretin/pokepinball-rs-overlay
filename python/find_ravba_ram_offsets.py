"""
One-time discovery tool for the external (read-only) RAVBA memory-reader
overlay project: finds the fixed, per-build offset (from the main module's
base address) of the pointer *slot* that holds RAVBA's `g_workRAM` (GBA
EWRAM, 256KB) global.

Why this is needed: that global is `calloc`'d at runtime (see
`src/core/gba/gba.cpp` in visualboyadvance-m / RAVBA), so the *buffer*
address changes every launch/reset. The *slot* holding that pointer,
however, sits at a fixed static offset from the module base for a given
build of RAVisualBoyAdvance-M.exe.

Approach (an exact-size heap-region scan does NOT work here -- a 256KB/32KB
request is small enough that the CRT heap manager sub-allocates it inside a
much larger reserved segment, so there's no dedicated VirtualAlloc region of
that exact size to look for). Instead:

  1. Enumerate every committed, private (heap/stack, not module/mapped-file)
     region in the process via VirtualQueryEx.
  2. Scan the main module's mapped image for every 8-byte-aligned value that
     looks like a pointer into one of those regions, with enough room left
     in the region to plausibly hold a 256KB buffer. This produces a noisy
     candidate list (most committed heap pointers in a module aren't
     g_workRAM), but scanning is cheap.
  3. Validate cheaply: read `gMain.systemFrameCount` (EWRAM abs `0x0200B10C`,
     see docs/ram-map.md) at every candidate once, sleep once (~0.5s total,
     not per-candidate), read again, and keep only candidates whose value
     increased plausibly and monotonically -- i.e. genuinely live emulator
     RAM, not a coincidental pointer match.

Read-only throughout: only OpenProcess + VirtualQueryEx + ReadProcessMemory
are used. Nothing is ever written to the target process.

Usage: run this while RAVisualBoyAdvance-M.exe is open with a ROM loaded
and actively running (not paused), then re-run once more later if you want
extra confidence -- the reported RVA should be stable across runs of the
*same* RAVBA build.
"""

import ctypes
import struct
import time
from bisect import bisect_right
from ctypes import wintypes

PROCESS_NAME = "RAVisualBoyAdvance-M.exe"

SIZE_WRAM = 0x40000  # EWRAM, g_workRAM

# gMain.systemFrameCount, per docs/ram-map.md: gMain at EWRAM abs 0x0200B0C0,
# systemFrameCount at gMain+0x4C -> abs 0x0200B10C -> offset 0xB10C into
# the g_workRAM buffer (EWRAM base is GBA address 0x02000000).
FRAME_COUNTER_OFFSET = 0x0200B10C - 0x02000000

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
TH32CS_SNAPPROCESS = 0x00000002
TH32CS_SNAPMODULE = 0x00000008
TH32CS_SNAPMODULE32 = 0x00000010
MEM_COMMIT = 0x1000
MEM_PRIVATE = 0x20000

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


class MEMORY_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BaseAddress", ctypes.c_void_p),
        ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wintypes.DWORD),
        ("PartitionId", wintypes.WORD),
        ("RegionSize", ctypes.c_size_t),
        ("State", wintypes.DWORD),
        ("Protect", wintypes.DWORD),
        ("Type", wintypes.DWORD),
    ]


def find_pid(name):
    snap = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == -1:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = PROCESSENTRY32()
        entry.dwSize = ctypes.sizeof(PROCESSENTRY32)
        found = kernel32.Process32First(snap, ctypes.byref(entry))
        while found:
            exe = entry.szExeFile.decode(errors="ignore")
            if exe.lower() == name.lower():
                return entry.th32ProcessID
            found = kernel32.Process32Next(snap, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snap)
    return None


def find_main_module(pid):
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
            return base, entry.modBaseSize
    finally:
        kernel32.CloseHandle(snap)
    return None, None


def read_memory(h_process, address, size):
    buf = ctypes.create_string_buffer(size)
    bytes_read = ctypes.c_size_t(0)
    ok = kernel32.ReadProcessMemory(
        h_process, ctypes.c_void_p(address), buf, size, ctypes.byref(bytes_read)
    )
    if not ok:
        return None
    return buf.raw[: bytes_read.value]


def enumerate_committed_private_regions(h_process):
    """All committed, private (heap/stack) regions -- excludes the module
    image itself and any memory-mapped files."""
    regions = []
    address = 0
    mbi = MEMORY_BASIC_INFORMATION()
    max_addr = 0x7FFFFFFF0000
    while address < max_addr:
        result = kernel32.VirtualQueryEx(
            h_process, ctypes.c_void_p(address), ctypes.byref(mbi), ctypes.sizeof(mbi)
        )
        if result == 0:
            break
        if mbi.State == MEM_COMMIT and mbi.Type == MEM_PRIVATE:
            regions.append((mbi.BaseAddress, mbi.BaseAddress + mbi.RegionSize))
        if mbi.RegionSize == 0:
            break
        address += mbi.RegionSize
    regions.sort()
    return regions


def region_end_if_contains(regions, region_starts, value):
    """If `value` falls inside one of `regions`, return that region's end
    address (so the caller can check how much room is left); else None."""
    i = bisect_right(region_starts, value) - 1
    if i < 0:
        return None
    start, end = regions[i]
    if start <= value < end:
        return end
    return None


def find_pointer_candidates(module_bytes, module_base, regions, min_room):
    region_starts = [r[0] for r in regions]
    candidates = []
    limit = len(module_bytes) - 8
    offset = 0
    while offset <= limit:
        value = struct.unpack_from("<Q", module_bytes, offset)[0]
        if value != 0:
            end = region_end_if_contains(regions, region_starts, value)
            if end is not None and (end - value) >= min_room:
                candidates.append((offset, value))
        offset += 8
    return candidates


def main():
    pid = find_pid(PROCESS_NAME)
    if pid is None:
        print(f"Could not find a running process named {PROCESS_NAME!r}.")
        print("Start RAVBA with a ROM loaded and try again.")
        return
    print(f"Found {PROCESS_NAME} at PID {pid}")

    module_base, module_size = find_main_module(pid)
    if module_base is None:
        print("Could not read the main module's base address/size.")
        return
    print(f"Main module base=0x{module_base:X} size=0x{module_size:X}")

    h_process = kernel32.OpenProcess(
        PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid
    )
    if not h_process:
        print("OpenProcess failed -- try running this script as the same")
        print("user as RAVBA (admin shouldn't be required for a same-user,")
        print("non-elevated target).")
        raise ctypes.WinError(ctypes.get_last_error())

    try:
        regions = enumerate_committed_private_regions(h_process)
        print(f"Committed private regions in process: {len(regions)}")

        module_bytes = read_memory(h_process, module_base, module_size)
        if module_bytes is None:
            print("Failed to read the main module's image.")
            return

        candidates = find_pointer_candidates(module_bytes, module_base, regions, SIZE_WRAM)
        print(f"Raw candidate pointer slots (module RVA -> region w/ >= 256KB room): {len(candidates)}")
        if not candidates:
            print("No candidates at all -- is a ROM actually loaded and running?")
            return

        # Batch the frame-counter validation across three samples two sleeps
        # apart -- not a sleep per candidate. Require the counter to
        # *strictly* increase each interval (not just non-decrease -- a
        # static/frozen pointer trivially passes a >=0 check) and for the
        # two deltas to be of a similar order, since a real, live frame
        # counter advances at a roughly steady rate.
        unique_values = {value for _, value in candidates}

        def read_all():
            out = {}
            for value in unique_values:
                data = read_memory(h_process, value + FRAME_COUNTER_OFFSET, 4)
                out[value] = struct.unpack("<I", data)[0] if data else None
            return out

        SAMPLE_INTERVAL = 0.5
        s1 = read_all()
        time.sleep(SAMPLE_INTERVAL)
        s2 = read_all()
        time.sleep(SAMPLE_INTERVAL)
        s3 = read_all()

        live_values = {}
        for value in unique_values:
            f1, f2, f3 = s1[value], s2[value], s3[value]
            if f1 is None or f2 is None or f3 is None:
                continue
            d1, d2 = f2 - f1, f3 - f2
            if d1 <= 0 or d2 <= 0:
                continue
            if max(d1, d2) > 3 * min(d1, d2):
                continue
            live_values[value] = (f1, f2, f3, d1, d2)

        confirmed = [
            (rva, value, *live_values[value])
            for rva, value in candidates
            if value in live_values
        ]

        if confirmed:
            print("\nConfirmed live g_workRAM pointer slot(s):")
            for rva, value, f1, f2, f3, d1, d2 in confirmed:
                print(
                    f"  module RVA 0x{rva:X}  ->  0x{value:X}  "
                    f"(systemFrameCount {f1} -> {f2} -> {f3}, deltas {d1}/{d2})"
                )
            print(
                "\nUse: buffer_addr = ReadPointer(module_base + RVA); "
                "ewram = ReadMemory(buffer_addr, 0x40000)"
            )
        else:
            print(
                "\nNo candidate was confirmed live via the frame-counter test. "
                "Make sure a ROM is loaded and actively running (not paused), "
                "then re-run."
            )
    finally:
        kernel32.CloseHandle(h_process)


if __name__ == "__main__":
    main()
