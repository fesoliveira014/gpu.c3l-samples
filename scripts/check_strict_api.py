#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_PARTS = {"build", "lib", ".git"}

FORBIDDEN_SYMBOLS = (
    "DeviceDesc",
    "create_device_from_desc",
    "BufferHandle",
    "ShaderHandle",
    "FrameToken",
    "alloc_frame_span",
    "ReadbackTicket",
    "DescriptorHeapMode",
    "TextureLayout",
    "SemaphoreHandle",
    "wait_queue_idle",
    "cmd_upload_buffer",
    "cmd_upload_texture",
    "cmd_readback_buffer",
    "cmd_readback_texture",
    "PersistentAllocDesc",
    "alloc_persistent_span",
    "create_sampler",
    "destroy_sampler",
    "create_texture_descriptor",
    "destroy_texture_descriptor",
    "create_texture_descriptors",
    "TextureDescriptorDesc",
    "BufferBarrier",
    "GlobalBarrier",
    "cmd_buffer_barrier",
    "cmd_global_barrier",
    "SHADER_HANDLE_INVALID",
    "create_shader",
    "destroy_shader",
    "poll_readback",
    "resolve_readback",
    "READBACK_NOT_READY",
    "upload_buffer_data",
    "upload_texture_data",
    "readback_buffer_data",
    "readback_texture_data",
    "MemoryKind",
    "begin_frame",
    "end_frame",
    "with_frame",
    "PersistentArenaStats",
    "free_persistent_span",
    "get_persistent_stats",
)

FORBIDDEN_PATTERNS = (
    re.compile(r"\bimport\s+gpu::compat\b"),
    re.compile(r"\bgpu::compat::"),
    re.compile(r"\bimport\s+gpu::vk\b"),
    re.compile(r"\bimport\s+vk\b"),
    re.compile(r"\bgpu::vk::"),
    re.compile(r"\bvk::"),
)
SYMBOL_PATTERN = re.compile(
    r"\b(?:" + "|".join(re.escape(symbol) for symbol in FORBIDDEN_SYMBOLS) + r")\b"
)


def main() -> int:
    findings: list[str] = []
    for path in sorted(ROOT.rglob("*.c3")):
        if any(part in SKIP_PARTS for part in path.relative_to(ROOT).parts):
            continue
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(),
            start=1,
        ):
            match = SYMBOL_PATTERN.search(line)
            if match is None:
                match = next(
                    (pattern.search(line) for pattern in FORBIDDEN_PATTERNS if pattern.search(line)),
                    None,
                )
            if match is not None:
                findings.append(
                    f"{path.relative_to(ROOT)}:{line_number}: forbidden strict API token {match.group(0)!r}"
                )

    if findings:
        print("\n".join(findings), file=sys.stderr)
        return 1
    print("strict sample API scan: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
