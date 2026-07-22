from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import check_strict_api


class StrictApiCheckTests(unittest.TestCase):
    def findings_for(self, source: str) -> list[str]:
        with tempfile.TemporaryDirectory() as temp_directory:
            root = Path(temp_directory)
            path = root / "probe.c3"
            path.write_text(source, encoding="utf-8")
            with mock.patch.object(check_strict_api, "ROOT", root):
                return check_strict_api.find_forbidden_retired_fields(
                    path,
                    source,
                )

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


if __name__ == "__main__":
    unittest.main()
