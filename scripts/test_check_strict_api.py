from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import check_strict_api


class StrictApiCheckTests(unittest.TestCase):
    def findings_for(
        self,
        source: str,
        check: str = "retired_fields",
    ) -> list[str]:
        with tempfile.TemporaryDirectory() as temp_directory:
            root = Path(temp_directory)
            path = root / "probe.c3"
            path.write_text(source, encoding="utf-8")
            with mock.patch.object(check_strict_api, "ROOT", root):
                if check == "tokens":
                    return check_strict_api.find_forbidden_strict_api_tokens(
                        path,
                        source,
                    )
                if check == "command_allocators":
                    return check_strict_api.find_command_allocator_policy(
                        path,
                        source,
                    )
                return check_strict_api.find_forbidden_retired_fields(path, source)

    def test_retired_field_survives_braces_in_lexical_content(self) -> None:
        prefixes = (
            '.debug_name = "}",\n',
            '.debug_name = "escaped \\\" }",\n',
            ".debug_name = `}`,\n",
            ".debug_name = `raw\n}\nvalue`,\n",
            ".debug_name = `raw `` }`,\n",
            ".width = '}',\n",
            "// }\n.width = 1,\n",
            "/* } /* { */ } */\n.width = 1,\n",
            "<* } *>\n.width = 1,\n",
        )
        for prefix in prefixes:
            with self.subTest(prefix=prefix):
                source = (
                    "module probe;\n"
                    "import gpu;\n"
                    "fn void probe() {\n"
                    "    gpu::TextureDesc desc = {\n"
                    f"        {prefix}"
                    "        .depth = 1,\n"
                    "    };\n"
                    "}\n"
                )
                findings = self.findings_for(source)
                self.assertEqual(
                    findings,
                    [
                        f"probe.c3:{5 + prefix.count(chr(10))}: "
                        "forbidden TextureDesc field '.depth'"
                    ],
                )

    def test_shebang_does_not_hide_retired_field(self) -> None:
        source = (
            "#! }\n"
            "module probe;\n"
            "import gpu;\n"
            "fn void probe() {\n"
            "    gpu::TextureViewDesc view = { .format = gpu::Format.RGBA8_UNORM };\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source),
            ["probe.c3:5: forbidden TextureViewDesc field '.format'"],
        )

    def test_doc_comment_closes_at_first_terminator(self) -> None:
        source = (
            "module probe;\n"
            "<* a literal <* does not nest *>\n"
            "fn void probe() {\n"
            "    gpu::TextureDesc desc = { .depth = 1 };\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source),
            ["probe.c3:4: forbidden TextureDesc field '.depth'"],
        )

    def test_retired_fields_in_reassignment_and_member_assignment(self) -> None:
        source = (
            "module probe;\n"
            "fn void probe() {\n"
            "    gpu::TextureDesc desc;\n"
            "    desc = { .dimension = gpu::TextureDimension.D2 };\n"
            "    desc.depth = 1;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source),
            [
                "probe.c3:4: forbidden TextureDesc field '.dimension'",
                "probe.c3:5: forbidden TextureDesc field '.depth'",
            ],
        )

    def test_reassignment_scanner_respects_type_and_lexical_content(self) -> None:
        source = (
            "module probe;\n"
            "fn void probe() {\n"
            "    gpu::RenderPassDesc desc;\n"
            "    desc.depth = null;\n"
            "    gpu::TextureDesc texture;\n"
            "    // texture.depth = 1;\n"
            "    ZString text = `texture = { .depth = 1 }`;\n"
            "}\n"
        )
        self.assertEqual(self.findings_for(source), [])

    def test_valid_depth_fields_are_not_texture_descriptor_fields(self) -> None:
        source = (
            "module probe;\n"
            "import gpu;\n"
            "fn void probe() {\n"
            "    gpu::ClearDepth clear = { .depth = 1.0f };\n"
            "    gpu::RenderPassDesc pass = { .depth = null };\n"
            "}\n"
        )
        self.assertEqual(self.findings_for(source), [])

    def test_removed_support_and_nested_stencil_fields_are_reported(self) -> None:
        source = (
            "module probe;\n"
            "import gpu;\n"
            "fn void probe() {\n"
            "    gpu::TextureFormatSupport support = { .dimensions = {} };\n"
            "    gpu::DepthTargetDesc target = {\n"
            "        .clear = { .stencil = 0 },\n"
            "    };\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source),
            [
                "probe.c3:4: forbidden TextureFormatSupport field '.dimensions'",
                "probe.c3:6: forbidden DepthTargetDesc field '.stencil'",
            ],
        )

    def test_retired_runtime_validation_field_is_reported(self) -> None:
        source = (
            "module probe;\n"
            "fn void probe() {\n"
            "    gpu::RuntimeDesc desc = { .enable_validation = true };\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source),
            ["probe.c3:3: forbidden RuntimeDesc field '.enable_validation'"],
        )

    def test_retired_runtime_validation_member_assignment_is_reported(self) -> None:
        source = (
            "module probe;\n"
            "fn void probe() {\n"
            "    gpu::RuntimeDesc desc;\n"
            "    desc.enable_validation = true;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source),
            ["probe.c3:4: forbidden RuntimeDesc field '.enable_validation'"],
        )

    def test_vulkan_validation_field_is_not_retired(self) -> None:
        source = (
            "module probe;\n"
            "fn void probe() {\n"
            "    gpu::RuntimeDesc desc = { .enable_vulkan_validation = true };\n"
            "}\n"
        )
        self.assertEqual(self.findings_for(source), [])

    def test_removed_dimension_support_is_a_forbidden_symbol(self) -> None:
        match = check_strict_api.SYMBOL_PATTERN.search(
            "gpu::TextureDimensionSupport support = {};"
        )
        self.assertIsNotNone(match)
        self.assertEqual(match.group(0), "TextureDimensionSupport")

    def test_sanitizer_preserves_offsets_and_newlines(self) -> None:
        source = '"}"\n`{}`\n/* } */\n<* { *>\n'
        sanitized = check_strict_api.sanitize_c3_structure(source)
        self.assertEqual(len(sanitized), len(source))
        self.assertEqual(sanitized.count("\n"), source.count("\n"))
        self.assertNotIn("{", sanitized)
        self.assertNotIn("}", sanitized)

    def test_strict_tokens_ignore_comments_and_strings(self) -> None:
        source = (
            "module probe;\n"
            "// gpu::compat:: FrameToken\n"
            "ZString text = `vk::DeviceDesc`;\n"
            "<* import gpu::vk *>\n"
        )
        self.assertEqual(self.findings_for(source, "tokens"), [])

    def test_queue_based_command_calls_are_reported(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Queue queue, gpu::GeneratedScratchDesc* desc, "
            "gpu::PipelineHandle pipeline) {\n"
            "    gpu::begin_commands(queue)!;\n"
            "    gpu::reserve_generated_scratch(queue, desc)!;\n"
            "    gpu::release_generated_scratch(queue, pipeline, "
            "gpu::GeneratedWorkKind.DRAW)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:3: queue-based begin_commands call",
                "probe.c3:4: queue-based reserve_generated_scratch call",
                "probe.c3:5: queue-based release_generated_scratch call",
            ],
        )

    def test_command_policy_ignores_lexical_content_and_accepts_pointer(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::CommandAllocator* allocator) {\n"
            "    // gpu::begin_commands(queue)!;\n"
            "    ZString retired = `gpu::reserve_generated_scratch(queue, desc)`;\n"
            "    gpu::begin_commands(allocator)!;\n"
            "}\n"
        )
        self.assertEqual(self.findings_for(source, "command_allocators"), [])

    def test_unbalanced_command_allocator_lifetime_is_reported(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    gpu::CommandAllocator allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:3: command allocator 'allocator' has no same-scope "
                "deferred destroy"
            ],
        )

    def test_deferred_command_allocator_destroy_balances_creation(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    gpu::CommandAllocator allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    defer (void)gpu::destroy_command_allocator(&allocator);\n"
            "}\n"
        )
        self.assertEqual(self.findings_for(source, "command_allocators"), [])

    def test_struct_field_allocator_needs_deferred_destroy(self) -> None:
        source = (
            "module probe;\n"
            "struct Worker { gpu::CommandAllocator allocator; }\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    Worker[4] workers;\n"
            "    workers[0].allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:5: command allocator 'workers[0].allocator' has no "
                "same-scope deferred destroy"
            ],
        )

    def test_struct_field_allocator_accepts_deferred_destroy(self) -> None:
        source = (
            "module probe;\n"
            "struct Worker { gpu::CommandAllocator allocator; }\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    Worker worker;\n"
            "    worker.allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    defer (void)gpu::destroy_command_allocator(&worker.allocator);\n"
            "}\n"
        )
        self.assertEqual(self.findings_for(source, "command_allocators"), [])

    def test_struct_field_allocator_accepts_outer_deferred_collection_cleanup(
        self,
    ) -> None:
        source = (
            "module probe;\n"
            "struct Worker { gpu::CommandAllocator allocator; }\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    Worker[] workers = {};\n"
            "    defer {\n"
            "        for (uint worker = 0; worker < workers.len; worker++) {\n"
            "            (void)gpu::destroy_command_allocator("
            "&workers[worker].allocator);\n"
            "        }\n"
            "    }\n"
            "    for (uint worker = 0; worker < workers.len; worker++) {\n"
            "        workers[worker].allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    }\n"
            "}\n"
        )
        self.assertEqual(self.findings_for(source, "command_allocators"), [])

    def test_collection_cleanup_deferred_after_loop_does_not_balance_creation(
        self,
    ) -> None:
        source = (
            "module probe;\n"
            "struct Worker { gpu::CommandAllocator allocator; }\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    Worker[] workers = {};\n"
            "    for (uint worker = 0; worker < workers.len; worker++) {\n"
            "        workers[worker].allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    }\n"
            "    defer {\n"
            "        for (uint worker = 0; worker < workers.len; worker++) {\n"
            "            (void)gpu::destroy_command_allocator("
            "&workers[worker].allocator);\n"
            "        }\n"
            "    }\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:6: command allocator 'workers[worker].allocator' "
                "has no same-scope deferred destroy"
            ],
        )

    def test_collection_destroy_deferred_before_creation_needs_cleanup_block(
        self,
    ) -> None:
        source = (
            "module probe;\n"
            "struct Worker { gpu::CommandAllocator allocator; }\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    Worker[1] workers;\n"
            "    defer (void)gpu::destroy_command_allocator("
            "&workers[0].allocator);\n"
            "    workers[0].allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:6: command allocator 'workers[0].allocator' has no "
                "same-scope deferred destroy"
            ],
        )

    def test_different_struct_field_destroy_does_not_balance_creation(self) -> None:
        source = (
            "module probe;\n"
            "struct Worker {\n"
            "    gpu::CommandAllocator graphics_allocator;\n"
            "    gpu::CommandAllocator compute_allocator;\n"
            "}\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    Worker worker;\n"
            "    worker.graphics_allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    defer (void)gpu::destroy_command_allocator("
            "&worker.compute_allocator);\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:8: command allocator 'worker.graphics_allocator' "
                "has no same-scope deferred destroy"
            ],
        )

    def test_different_fixed_index_destroy_does_not_balance_creation(self) -> None:
        source = (
            "module probe;\n"
            "struct Worker { gpu::CommandAllocator allocator; }\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    Worker[2] workers;\n"
            "    workers[0].allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    defer (void)gpu::destroy_command_allocator("
            "&workers[1].allocator);\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:5: command allocator 'workers[0].allocator' has no "
                "same-scope deferred destroy"
            ],
        )

    def test_each_command_allocator_creation_needs_a_destroy(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    gpu::CommandAllocator allocator;\n"
            "    allocator = gpu::create_command_allocator(device, queue)!;\n"
            "    gpu::destroy_command_allocator(&allocator)!;\n"
            "    allocator = gpu::create_command_allocator(device, queue)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:4: command allocator 'allocator' has no same-scope "
                "deferred destroy",
                "probe.c3:6: command allocator 'allocator' has no same-scope "
                "deferred destroy",
            ],
        )

    def test_queue_names_are_resolved_per_function(self) -> None:
        source = (
            "module probe;\n"
            "fn void? retired(gpu::Queue work) {\n"
            "    gpu::begin_commands(work)!;\n"
            "}\n"
            "fn void? current(gpu::CommandAllocator* work) {\n"
            "    gpu::begin_commands(work)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            ["probe.c3:3: queue-based begin_commands call"],
        )

    def test_queue_returning_expression_is_reported(self) -> None:
        source = (
            "module probe;\n"
            "fn gpu::Queue? choose(gpu::Device* device) => {};\n"
            "fn void? probe(gpu::Device* device) {\n"
            "    gpu::begin_commands(choose(device)!)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            ["probe.c3:4: queue-based begin_commands call"],
        )

    def test_inner_allocator_shadow_does_not_inherit_outer_queue_type(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Queue work, gpu::CommandAllocator* allocator) {\n"
            "    {\n"
            "        gpu::CommandAllocator* work = allocator;\n"
            "        gpu::begin_commands(work)!;\n"
            "    }\n"
            "    gpu::begin_commands(work)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            ["probe.c3:7: queue-based begin_commands call"],
        )

    def test_conditional_ordinary_destroy_does_not_balance_creation(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue, bool cleanup) {\n"
            "    gpu::CommandAllocator allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    if (cleanup) gpu::destroy_command_allocator(&allocator)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:3: command allocator 'allocator' has no same-scope "
                "deferred destroy"
            ],
        )

    def test_conditional_deferred_destroy_does_not_balance_creation(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue, bool cleanup) {\n"
            "    gpu::CommandAllocator allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    if (cleanup) defer (void)gpu::destroy_command_allocator("
            "&allocator);\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:3: command allocator 'allocator' has no same-scope "
                "deferred destroy"
            ],
        )

    def test_conditional_deferred_block_does_not_balance_field_creation(self) -> None:
        source = (
            "module probe;\n"
            "struct Worker { gpu::CommandAllocator allocator; }\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue, bool cleanup) {\n"
            "    Worker worker;\n"
            "    worker.allocator = gpu::create_command_allocator(device, queue)!;\n"
            "    if (cleanup) defer {\n"
            "        (void)gpu::destroy_command_allocator(&worker.allocator);\n"
            "    }\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:5: command allocator 'worker.allocator' has no "
                "same-scope deferred destroy"
            ],
        )

    def test_unreachable_ordinary_destroy_does_not_balance_creation(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    gpu::CommandAllocator allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    return;\n"
            "    gpu::destroy_command_allocator(&allocator)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:3: command allocator 'allocator' has no same-scope "
                "deferred destroy"
            ],
        )

    def test_nested_deferred_destroy_does_not_balance_outer_creation(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    gpu::CommandAllocator allocator = "
            "gpu::create_command_allocator(device, queue)!;\n"
            "    {\n"
            "        defer (void)gpu::destroy_command_allocator(&allocator);\n"
            "    }\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:3: command allocator 'allocator' has no same-scope "
                "deferred destroy"
            ],
        )

    def test_deferred_destroy_registered_before_creation_does_not_balance(self) -> None:
        source = (
            "module probe;\n"
            "fn void? probe(gpu::Device* device, gpu::Queue queue) {\n"
            "    gpu::CommandAllocator allocator;\n"
            "    defer (void)gpu::destroy_command_allocator(&allocator);\n"
            "    allocator = gpu::create_command_allocator(device, queue)!;\n"
            "}\n"
        )
        self.assertEqual(
            self.findings_for(source, "command_allocators"),
            [
                "probe.c3:5: command allocator 'allocator' has no same-scope "
                "deferred destroy"
            ],
        )


if __name__ == "__main__":
    unittest.main()
