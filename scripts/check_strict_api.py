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
    "TextureUse",
    "prior_use",
    "from_use",
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
    "TextureDimension",
    "TextureDimensionSupport",
    "D24_UNORM_S8_UINT",
    "ClearDepthStencil",
    "SAMPLER_INVALID",
    "publish_sampler",
)

FORBIDDEN_PATTERNS = (
    re.compile(r"\bimport\s+gpu::compat\b"),
    re.compile(r"\bgpu::compat::"),
    re.compile(r"\bimport\s+gpu::vk\b"),
    re.compile(r"\bimport\s+vk\b"),
    re.compile(r"\bgpu::vk::"),
    re.compile(r"\bvk::"),
    re.compile(r"\bgpu::Sampler\b"),
)
SYMBOL_PATTERN = re.compile(
    r"\b(?:" + "|".join(re.escape(symbol) for symbol in FORBIDDEN_SYMBOLS) + r")\b"
)
RETIRED_FIELD_RULES = (
    ("RuntimeDesc", ("enable_validation",)),
    ("TextureDesc", ("dimension", "depth")),
    ("TextureViewDesc", ("format",)),
    ("TextureFormatSupport", ("dimensions",)),
    ("DepthTargetDesc", ("stencil",)),
)


def sanitize_c3_structure(text: str) -> str:
    sanitized = list(text)
    state = "code"
    nesting = 0
    index = 0

    def mask(offset: int) -> None:
        if sanitized[offset] != "\n":
            sanitized[offset] = " "

    while index < len(text):
        if state == "code":
            if index == 0 and text.startswith("#!", index):
                mask(index)
                mask(index + 1)
                index += 2
                state = "line_comment"
            elif text.startswith("//", index):
                mask(index)
                mask(index + 1)
                index += 2
                state = "line_comment"
            elif text.startswith("/*", index):
                mask(index)
                mask(index + 1)
                index += 2
                nesting = 1
                state = "block_comment"
            elif text.startswith("<*", index):
                mask(index)
                mask(index + 1)
                index += 2
                nesting = 1
                state = "doc_comment"
            elif text[index] == '"':
                mask(index)
                index += 1
                state = "string"
            elif text[index] == "'":
                mask(index)
                index += 1
                state = "character"
            elif text[index] == "`":
                mask(index)
                index += 1
                state = "raw_string"
            else:
                index += 1
        elif state == "line_comment":
            if text[index] == "\n":
                state = "code"
            else:
                mask(index)
            index += 1
        elif state == "block_comment":
            if text.startswith("/*", index):
                mask(index)
                mask(index + 1)
                index += 2
                nesting += 1
            elif text.startswith("*/", index):
                mask(index)
                mask(index + 1)
                index += 2
                nesting -= 1
                if nesting == 0:
                    state = "code"
            else:
                mask(index)
                index += 1
        elif state == "doc_comment":
            if text.startswith("*>", index):
                mask(index)
                mask(index + 1)
                index += 2
                state = "code"
            else:
                mask(index)
                index += 1
        elif state in ("string", "character"):
            delimiter = '"' if state == "string" else "'"
            if text[index] == "\\" and index + 1 < len(text):
                mask(index)
                mask(index + 1)
                index += 2
            else:
                closing = text[index] == delimiter
                mask(index)
                index += 1
                if closing:
                    state = "code"
        elif state == "raw_string":
            if (
                text[index] == "`"
                and index + 1 < len(text)
                and text[index + 1] == "`"
            ):
                mask(index)
                mask(index + 1)
                index += 2
            else:
                closing = text[index] == "`"
                mask(index)
                index += 1
                if closing:
                    state = "code"

    return "".join(sanitized)


def find_forbidden_retired_fields(path: Path, text: str) -> list[str]:
    finding_records: list[tuple[int, str]] = []
    structural_text = sanitize_c3_structure(text)

    brace_stack: list[int] = []
    brace_pairs: dict[int, int] = {}
    for offset, character in enumerate(structural_text):
        if character == "{":
            brace_stack.append(offset)
        elif character == "}" and brace_stack:
            brace_pairs[brace_stack.pop()] = offset

    def enclosing_scope_end(offset: int) -> int:
        scopes = [
            closing
            for opening, closing in brace_pairs.items()
            if opening < offset < closing
        ]
        return min(scopes, default=len(structural_text))

    reported_offsets: set[tuple[str, int]] = set()

    def report(type_name: str, field: str, offset: int) -> None:
        key = (type_name, offset)
        if key in reported_offsets:
            return
        reported_offsets.add(key)
        line_number = text.count("\n", 0, offset) + 1
        finding_records.append(
            (
                offset,
                f"{path.relative_to(ROOT)}:{line_number}: "
                f"forbidden {type_name} field {field!r}",
            )
        )

    for type_name, field_names in RETIRED_FIELD_RULES:
        declaration_pattern = re.compile(
            rf"\b(?:gpu::)?{re.escape(type_name)}\b"
            rf"\s*(?:\[[^\]\n]*\]|\*)?\s+([A-Za-z_]\w*)"
            r"(?=\s*(?:[=;,)\[]|$))"
        )
        field_pattern = re.compile(
            r"\.(?P<field>"
            + "|".join(re.escape(field) for field in field_names)
            + r")\s*="
        )
        for declaration in declaration_pattern.finditer(structural_text):
            variable = declaration.group(1)
            search_start = declaration.start(1)
            search_end = enclosing_scope_end(declaration.start())
            assignment_pattern = re.compile(
                rf"\b{re.escape(variable)}\b\s*=\s*\{{"
            )
            for initializer in assignment_pattern.finditer(
                structural_text,
                search_start,
                search_end,
            ):
                opening_brace = initializer.end() - 1
                closing_brace = brace_pairs.get(opening_brace)
                if closing_brace is None or closing_brace > search_end:
                    continue
                body = structural_text[opening_brace + 1 : closing_brace]
                for match in field_pattern.finditer(body):
                    absolute_offset = opening_brace + 1 + match.start()
                    report(
                        type_name,
                        f".{match.group('field')}",
                        absolute_offset,
                    )

            member_pattern = re.compile(
                rf"\b{re.escape(variable)}\b\s*"
                rf"\.(?P<field>{'|'.join(re.escape(field) for field in field_names)})"
                r"\s*="
            )
            for match in member_pattern.finditer(
                structural_text,
                search_start,
                search_end,
            ):
                report(
                    type_name,
                    f".{match.group('field')}",
                    match.start() + match.group(0).index("."),
                )
    return [message for _, message in sorted(finding_records)]


def main() -> int:
    findings: list[str] = []
    for path in sorted(ROOT.rglob("*.c3")):
        if any(part in SKIP_PARTS for part in path.relative_to(ROOT).parts):
            continue
        text = path.read_text(encoding="utf-8")
        for line_number, line in enumerate(
            text.splitlines(),
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
        findings.extend(find_forbidden_retired_fields(path, text))

    if findings:
        print("\n".join(findings), file=sys.stderr)
        return 1
    print("strict sample API scan: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
