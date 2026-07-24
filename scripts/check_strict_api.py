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
ORDINARY_COMMANDS = frozenset(
    {
        "cmd_barrier",
        "cmd_begin_label",
        "cmd_begin_render_pass",
        "cmd_begin_render_pass_with_state",
        "cmd_bind_pipeline",
        "cmd_copy_buffer",
        "cmd_copy_buffer_to_texture",
        "cmd_copy_texture_to_buffer",
        "cmd_dispatch",
        "cmd_dispatch_indirect",
        "cmd_draw",
        "cmd_draw_indexed",
        "cmd_draw_indexed_indirect",
        "cmd_draw_indexed_indirect_count",
        "cmd_draw_indirect",
        "cmd_end_label",
        "cmd_end_render_pass",
        "cmd_fill_buffer",
        "cmd_set_depth_state",
        "cmd_set_graphics_state",
        "cmd_set_raster_state",
        "cmd_set_scissor",
        "cmd_set_viewport",
        "cmd_texture_barrier",
    }
)
GENERATED_COMMANDS = frozenset(
    {
        "cmd_dispatch_generated",
        "cmd_draw_generated",
        "cmd_draw_indexed_generated",
    }
)
EXPECTED_ORDINARY_COMMAND_CALLS = 182
EXPECTED_GENERATED_COMMAND_CALLS = {
    "cmd_draw_indexed_generated": 1,
}


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


def command_call_records(
    path: Path,
    text: str,
) -> list[tuple[Path, int, str, bool]]:
    structural_text = sanitize_c3_structure(text)
    names = sorted(ORDINARY_COMMANDS | GENERATED_COMMANDS, key=len, reverse=True)
    pattern = re.compile(
        r"\bgpu::(?P<name>"
        + "|".join(re.escape(name) for name in names)
        + r")\s*\("
    )
    records: list[tuple[Path, int, str, bool]] = []
    for match in pattern.finditer(structural_text):
        depth = 1
        cursor = match.end()
        while cursor < len(structural_text) and depth:
            if structural_text[cursor] == "(":
                depth += 1
            elif structural_text[cursor] == ")":
                depth -= 1
            cursor += 1
        if depth:
            continue
        while cursor < len(structural_text) and structural_text[cursor].isspace():
            cursor += 1
        records.append(
            (
                path,
                match.start(),
                match.group("name"),
                cursor < len(structural_text) and structural_text[cursor] == "!",
            )
        )
    return records


def find_fast_command_call_policy(path: Path, text: str) -> list[str]:
    findings: list[str] = []
    for _, offset, name, propagates in command_call_records(path, text):
        line_number = text.count("\n", 0, offset) + 1
        if name in ORDINARY_COMMANDS and propagates:
            findings.append(
                f"{path.relative_to(ROOT)}:{line_number}: "
                f"FAST ordinary command {name!r} must not propagate a fault"
            )
        elif name in GENERATED_COMMANDS and not propagates:
            findings.append(
                f"{path.relative_to(ROOT)}:{line_number}: "
                f"generated command {name!r} must propagate its optional result"
            )
    return findings


def find_fast_runtime_policy(path: Path, text: str) -> list[str]:
    structural_text = sanitize_c3_structure(text)
    brace_stack: list[int] = []
    brace_pairs: dict[int, int] = {}
    for offset, character in enumerate(structural_text):
        if character == "{":
            brace_stack.append(offset)
        elif character == "}" and brace_stack:
            brace_pairs[brace_stack.pop()] = offset

    findings: list[tuple[int, str]] = []
    pattern = re.compile(
        r"\b(?:gpu::)?RuntimeDesc\s+(?P<name>[A-Za-z_]\w*)\s*=\s*\{"
    )
    for match in pattern.finditer(structural_text):
        opening = match.end() - 1
        closing = brace_pairs.get(opening)
        if closing is None:
            continue
        body = structural_text[opening + 1 : closing]
        line_number = text.count("\n", 0, match.start()) + 1
        if not re.search(
            r"\.contract_validation\s*=\s*"
            r"gpu::ContractValidation\.TRUSTED\s*,",
            body,
        ):
            findings.append(
                (
                    match.start(),
                    f"{path.relative_to(ROOT)}:{line_number}: "
                    f"RuntimeDesc {match.group('name')!r} must select TRUSTED",
                )
            )
        if not re.search(
            r"\.track_resource_lifetimes\s*=\s*false\s*,",
            body,
        ):
            findings.append(
                (
                    match.start(),
                    f"{path.relative_to(ROOT)}:{line_number}: "
                    f"RuntimeDesc {match.group('name')!r} must disable "
                    "resource lifetime tracking",
                )
            )
    return [message for _, message in sorted(findings)]


def find_fast_target_profile(path: Path, text: str) -> list[str]:
    findings: list[str] = []
    target_pattern = re.compile(
        r'(?ms)^    "(?P<name>[^"]+)":\s*\{\n'
        r"(?P<body>.*?)(?=^    \},?$)"
    )
    for match in target_pattern.finditer(text):
        body = match.group("body")
        if '"type": "executable"' not in body:
            continue
        if not re.search(
            r'"features"\s*:\s*\[[^\]]*"GPU_FAST_COMMANDS"[^\]]*\]',
            body,
        ):
            line_number = text.count("\n", 0, match.start()) + 1
            findings.append(
                f"{path.relative_to(ROOT)}:{line_number}: "
                f"executable target {match.group('name')!r} must enable "
                "GPU_FAST_COMMANDS"
            )
        if not re.search(
            r'"features"\s*:\s*\[[^\]]*"DIRECT_COMMAND_TOKENS"[^\]]*\]',
            body,
        ):
            line_number = text.count("\n", 0, match.start()) + 1
            findings.append(
                f"{path.relative_to(ROOT)}:{line_number}: "
                f"FAST executable target {match.group('name')!r} must enable "
                "DIRECT_COMMAND_TOKENS"
            )
    return findings


def find_fast_command_totals(
    records: list[tuple[Path, int, str, bool]],
) -> list[str]:
    ordinary_count = sum(name in ORDINARY_COMMANDS for _, _, name, _ in records)
    generated_counts = {
        name: sum(record_name == name for _, _, record_name, _ in records)
        for name in GENERATED_COMMANDS
    }
    findings: list[str] = []
    if ordinary_count != EXPECTED_ORDINARY_COMMAND_CALLS:
        findings.append(
            "FAST sample command audit expected "
            f"{EXPECTED_ORDINARY_COMMAND_CALLS} ordinary calls, found "
            f"{ordinary_count}"
        )
    expected_generated = {
        name: count
        for name, count in EXPECTED_GENERATED_COMMAND_CALLS.items()
        if count
    }
    actual_generated = {
        name: count
        for name, count in generated_counts.items()
        if count
    }
    if actual_generated != expected_generated:
        findings.append(
            "FAST sample generated-command audit expected "
            f"{expected_generated!r}, found {actual_generated!r}"
        )
    return findings


def find_forbidden_strict_api_tokens(path: Path, text: str) -> list[str]:
    structural_text = sanitize_c3_structure(text)
    findings: list[tuple[int, str]] = []
    for match in SYMBOL_PATTERN.finditer(structural_text):
        findings.append(
            (
                match.start(),
                f"{path.relative_to(ROOT)}:"
                f"{text.count(chr(10), 0, match.start()) + 1}: "
                f"forbidden strict API token {match.group(0)!r}",
            )
        )
    for pattern in FORBIDDEN_PATTERNS:
        for match in pattern.finditer(structural_text):
            findings.append(
                (
                    match.start(),
                    f"{path.relative_to(ROOT)}:"
                    f"{text.count(chr(10), 0, match.start()) + 1}: "
                    f"forbidden strict API token {match.group(0)!r}",
                )
            )
    return [message for _, message in sorted(findings)]


def find_command_allocator_policy(path: Path, text: str) -> list[str]:
    structural_text = sanitize_c3_structure(text)
    findings: list[tuple[int, str]] = []

    brace_stack: list[int] = []
    brace_pairs: dict[int, int] = {}
    for offset, character in enumerate(structural_text):
        if character == "{":
            brace_stack.append(offset)
        elif character == "}" and brace_stack:
            brace_pairs[brace_stack.pop()] = offset

    function_pattern = re.compile(
        r"\bfn\s+"
        r"(?P<return>(?:[A-Za-z_]\w*::)*[A-Za-z_]\w*"
        r"(?:\s*\*)?\??)\s+"
        r"(?P<name>[A-Za-z_]\w*)\s*"
        r"\((?P<params>[^)]*)\)[^{;]*\{"
    )
    functions: list[dict[str, object]] = []
    return_signature_pattern = re.compile(
        r"\bfn\s+"
        r"(?P<return>(?:[A-Za-z_]\w*::)*[A-Za-z_]\w*"
        r"(?:\s*\*)?\??)\s+"
        r"(?P<name>[A-Za-z_]\w*)\s*\("
    )
    return_types = {
        match.group("name"): match.group("return")
        for match in return_signature_pattern.finditer(structural_text)
    }
    for match in function_pattern.finditer(structural_text):
        opening = match.end() - 1
        closing = brace_pairs.get(opening)
        if closing is None:
            continue
        functions.append(
            {
                "match": match,
                "opening": opening,
                "closing": closing,
                "declarations": [],
            }
        )

    struct_pattern = re.compile(r"\bstruct\s+([A-Za-z_]\w*)\s*\{")
    struct_fields: dict[str, dict[str, str]] = {}
    for match in struct_pattern.finditer(structural_text):
        opening = match.end() - 1
        closing = brace_pairs.get(opening)
        if closing is None:
            continue
        fields: dict[str, str] = {}
        field_pattern = re.compile(
            r"\b(?P<type>(?:gpu::)?(?:Queue|CommandAllocator)"
            r"(?:\s*\[[^\]\n]*\]|\s*\*)*)"
            r"\s+(?P<name>[A-Za-z_]\w*)"
        )
        for field in field_pattern.finditer(
            structural_text,
            opening + 1,
            closing,
        ):
            fields[field.group("name")] = field.group("type")
        struct_fields[match.group(1)] = fields

    def type_kind(type_name: str) -> str:
        normalized = re.sub(r"\s+", "", type_name).removeprefix("gpu::")
        base = re.sub(r"(?:\[[^\]]*\]|\*|\?)+$", "", normalized)
        if base == "Queue":
            return "queue"
        if base == "CommandAllocator":
            return "allocator"
        if base in struct_fields:
            return f"struct:{base}"
        return ""

    def scope_at(offset: int, function: dict[str, object]) -> int:
        opening = int(function["opening"])
        closing = int(function["closing"])
        scopes = [
            scope_opening
            for scope_opening, scope_closing in brace_pairs.items()
            if opening <= scope_opening < offset < scope_closing <= closing
        ]
        return max(scopes, default=opening)

    known_types = ["Queue", "CommandAllocator", *struct_fields]
    type_alternatives = "|".join(
        sorted((re.escape(name) for name in known_types), key=len, reverse=True)
    )
    declaration_pattern = re.compile(
        rf"\b(?P<type>(?:gpu::)?(?:{type_alternatives})"
        r"(?:\s*\[[^\]\n]*\]|\s*\*)*)"
        r"\s+(?P<name>[A-Za-z_]\w*)"
    )
    for function in functions:
        match = function["match"]
        assert isinstance(match, re.Match)
        opening = int(function["opening"])
        closing = int(function["closing"])
        declarations: list[tuple[int, int, str, str]] = []
        for declaration in declaration_pattern.finditer(match.group("params")):
            declarations.append(
                (
                    match.start("params") + declaration.start(),
                    opening,
                    declaration.group("name"),
                    type_kind(declaration.group("type")),
                )
            )
        for declaration in declaration_pattern.finditer(
            structural_text,
            opening + 1,
            closing,
        ):
            declarations.append(
                (
                    declaration.start(),
                    scope_at(declaration.start(), function),
                    declaration.group("name"),
                    type_kind(declaration.group("type")),
                )
            )
        function["declarations"] = declarations

    def containing_function(offset: int) -> dict[str, object] | None:
        candidates = [
            function
            for function in functions
            if int(function["opening"]) < offset < int(function["closing"])
        ]
        return max(candidates, key=lambda item: int(item["opening"]), default=None)

    def resolve_name(
        name: str,
        offset: int,
        function: dict[str, object],
    ) -> str:
        call_scopes = {
            scope_opening
            for scope_opening, scope_closing in brace_pairs.items()
            if int(function["opening"]) <= scope_opening < offset < scope_closing
            and scope_closing <= int(function["closing"])
        }
        declarations = function["declarations"]
        assert isinstance(declarations, list)
        candidates = [
            declaration
            for declaration in declarations
            if declaration[0] < offset
            and declaration[1] in call_scopes
            and declaration[2] == name
        ]
        if not candidates:
            return ""
        return max(candidates, key=lambda item: (item[1], item[0]))[3]

    def expression_kind(
        expression: str,
        offset: int,
        function: dict[str, object],
    ) -> str:
        normalized = expression.strip()
        normalized = re.sub(r"[!~]+\s*$", "", normalized).strip()
        while normalized.startswith("(") and normalized.endswith(")"):
            normalized = normalized[1:-1].strip()
        normalized = normalized.removeprefix("&").strip()

        call = re.match(
            r"^(?:(?:[A-Za-z_]\w*)::)*(?P<name>[A-Za-z_]\w*)\s*\(",
            normalized,
        )
        if call is not None:
            name = call.group("name")
            if name == "get_queue":
                return "queue"
            return type_kind(return_types.get(name, ""))

        members = normalized.split(".")
        if not members:
            return ""
        root = re.sub(r"(?:\s*\[[^\]]*\])+$", "", members[0]).strip()
        if not re.fullmatch(r"[A-Za-z_]\w*", root):
            return ""
        kind = resolve_name(root, offset, function)
        for member in members[1:]:
            member = re.sub(r"(?:\s*\[[^\]]*\])+$", "", member).strip()
            if not re.fullmatch(r"[A-Za-z_]\w*", member):
                return ""
            if kind == "allocator" and member == "queue":
                kind = "queue"
                continue
            if not kind.startswith("struct:"):
                return ""
            struct_name = kind.removeprefix("struct:")
            kind = type_kind(struct_fields.get(struct_name, {}).get(member, ""))
        return kind

    retired_calls = re.compile(
        r"\b(?:gpu::)?(?P<name>begin_commands|reserve_generated_scratch|"
        r"release_generated_scratch)\s*\("
    )
    for call in retired_calls.finditer(structural_text):
        function = containing_function(call.start())
        if function is None:
            continue
        argument_start = call.end()
        index = argument_start
        nesting = 0
        while index < len(structural_text):
            character = structural_text[index]
            if character in "([{":
                nesting += 1
            elif character in ")]}":
                if nesting == 0:
                    break
                nesting -= 1
            elif character == "," and nesting == 0:
                break
            index += 1
        first_argument = structural_text[argument_start:index]
        if expression_kind(first_argument, call.start(), function) == "queue":
            findings.append(
                (
                    call.start(),
                    f"{path.relative_to(ROOT)}:"
                    f"{text.count(chr(10), 0, call.start()) + 1}: "
                    f"queue-based {call.group('name')} call",
                )
            )

    lvalue = (
        r"[A-Za-z_]\w*"
        r"(?:\s*\[[^\]\n]+\]|\s*\.\s*[A-Za-z_]\w*)*"
    )
    create_pattern = re.compile(
        rf"\b(?P<target>{lvalue})\s*=\s*"
        r"(?:gpu::)?create_command_allocator\s*\("
    )
    destroy_pattern = re.compile(
        rf"\b(?:gpu::)?destroy_command_allocator\s*\(\s*&\s*"
        rf"(?P<target>{lvalue})"
    )
    deferred_destroy_pattern = re.compile(
        rf"\bdefer\s+(?!catch\b|try\b)(?:\(\s*void\s*\)\s*)?"
        rf"(?:gpu::)?destroy_command_allocator\s*\(\s*&\s*"
        rf"(?P<target>{lvalue})"
    )
    deferred_block_pattern = re.compile(r"\bdefer\s+(?!catch\b|try\b)\{")

    def canonical_target(target: str) -> str:
        compact = re.sub(r"\s+", "", target)

        def normalize_index(match: re.Match[str]) -> str:
            index = match.group(1)
            return f"[{index}]" if index.isdecimal() else "[]"

        return re.sub(r"\[([^\]]+)\]", normalize_index, compact)

    def direct_scope_statement(offset: int, scope: int) -> bool:
        statement_start = max(
            scope + 1,
            structural_text.rfind(";", scope + 1, offset) + 1,
            structural_text.rfind("}", scope + 1, offset) + 1,
        )
        return not structural_text[statement_start:offset].strip()

    for function in functions:
        opening = int(function["opening"])
        closing = int(function["closing"])
        body_start = opening + 1
        body = structural_text[body_start:closing]
        creations: dict[str, list[tuple[int, int, str, bool]]] = {}
        for match in create_pattern.finditer(body):
            target = match.group("target")
            offset = body_start + match.start("target")
            if expression_kind(target, offset, function) != "allocator":
                continue
            canonical = canonical_target(target)
            creations.setdefault(canonical, []).append(
                (
                    offset,
                    scope_at(offset, function),
                    re.sub(r"\s+", "", target),
                    "[]" in canonical,
                )
            )
        deferred_destroys: dict[str, list[tuple[int, int, bool]]] = {}
        for match in deferred_destroy_pattern.finditer(body):
            offset = body_start + match.start()
            defer_scope = scope_at(offset, function)
            if not direct_scope_statement(offset, defer_scope):
                continue
            target = canonical_target(match.group("target"))
            deferred_destroys.setdefault(target, []).append(
                (offset, defer_scope, False)
            )

        for defer_block in deferred_block_pattern.finditer(body):
            offset = body_start + defer_block.start()
            defer_scope = scope_at(offset, function)
            if not direct_scope_statement(offset, defer_scope):
                continue
            block_opening = body_start + defer_block.end() - 1
            block_closing = brace_pairs.get(block_opening)
            if block_closing is None:
                continue
            for destroy in destroy_pattern.finditer(
                structural_text,
                block_opening + 1,
                block_closing,
            ):
                target = canonical_target(destroy.group("target"))
                deferred_destroys.setdefault(target, []).append(
                    (offset, defer_scope, True)
                )

        for canonical, creation_records in creations.items():
            available_destroys = deferred_destroys.get(canonical, []).copy()
            for (
                creation_offset,
                creation_scope,
                display,
                collection,
            ) in creation_records:
                matching_destroy = next(
                    (
                        destroy
                        for destroy in available_destroys
                        if (
                            collection
                            and destroy[2]
                            and destroy[0] < creation_offset
                            and brace_pairs.get(destroy[1], -1) > creation_offset
                        )
                        or (
                            destroy[0] > creation_offset
                            and destroy[1] == creation_scope
                        )
                    ),
                    None,
                )
                if matching_destroy is not None:
                    if not (collection and matching_destroy[2]):
                        available_destroys.remove(matching_destroy)
                    continue
                findings.append(
                    (
                        creation_offset,
                        f"{path.relative_to(ROOT)}:"
                        f"{text.count(chr(10), 0, creation_offset) + 1}: "
                        f"command allocator {display!r} has no same-scope "
                        "deferred destroy",
                    )
                )

    return [message for _, message in sorted(findings)]


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
    project_path = ROOT / "project.json"
    findings.extend(
        find_fast_target_profile(
            project_path,
            project_path.read_text(encoding="utf-8"),
        )
    )
    command_records: list[tuple[Path, int, str, bool]] = []
    for path in sorted(ROOT.rglob("*.c3")):
        if any(part in SKIP_PARTS for part in path.relative_to(ROOT).parts):
            continue
        text = path.read_text(encoding="utf-8")
        findings.extend(find_forbidden_strict_api_tokens(path, text))
        findings.extend(find_command_allocator_policy(path, text))
        findings.extend(find_forbidden_retired_fields(path, text))
        findings.extend(find_fast_command_call_policy(path, text))
        findings.extend(find_fast_runtime_policy(path, text))
        command_records.extend(command_call_records(path, text))
    findings.extend(find_fast_command_totals(command_records))

    if findings:
        print("\n".join(findings), file=sys.stderr)
        return 1
    print("strict sample API scan: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
