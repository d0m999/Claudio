# Host icon sources

These two monochrome SVG files are the geometry masters approved in the
`cli-tool-mapping-flat-20260806` mockup. The generated template PDFs under
`gui/Sources/ClaudioGUI/Resources/HostIcons/` are runtime artifacts; edit the SVG masters and
regenerate the PDFs instead of editing PDF bytes directly. Use
`swift scripts/generate-host-icon-pdf.swift assets/host-icons/codex.svg gui/Sources/ClaudioGUI/Resources/HostIcons/codex.pdf`
for the runtime PDF; `sips` is not suitable because it rasterizes the transparent SVG into an
opaque image, which macOS template rendering tints as a solid square.

| Asset | Geometry provenance | SHA-256 |
| --- | --- | --- |
| `claude.svg` | Claude Spark geometry, normalized to the approved 24×24 mockup from the [Anthropic Press Kit](https://www.anthropic.com/press-kit) | `b8539c535a7804d0403bcecb6e6281fcbe4b56dd97b2e2d51a9ef53827f33c04` |
| `codex.svg` | Approved 20×20 OpenAI 2025 Blossom geometry, normalized to the 24×24 runtime canvas, from the [OpenAI Design Guidelines](https://openai.com/brand/) | `2674292c146cd5c5c41819e19c6edb268bbba73832e088aa338750bfb92b8b4e` |

Claude and its marks belong to Anthropic PBC. OpenAI, Codex, and the OpenAI 2025 Blossom mark
belong to OpenAI. Their use here identifies which installed CLI integration a factual status applies
to; it does not make either mark part of the claudi0 brand and does not imply sponsorship or
endorsement.

The runtime tints `#E48667` / `#BD6549` (Claude) and `#79C995` / `#318A50` (Codex) are claudi0
connection-state colors. They are not represented as official brand colors.
