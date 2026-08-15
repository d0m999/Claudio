# Security Policy

## Supported versions

Security fixes are provided for the latest published Claudio release. Before the first public release, reports are evaluated against the current `main` branch.

## Reporting a vulnerability

Do not open a public issue containing a vulnerability, signing material, host configuration, prompts, responses, receipts, logs, project paths, or other private data.

Use GitHub's private vulnerability-reporting flow at [Security Advisories](https://github.com/d0m999/Claudio/security/advisories/new). Include only the minimum material needed to reproduce the problem:

- affected Claudio version and installation method;
- macOS version and CPU architecture;
- affected host and host version, if relevant;
- impact and reproducible steps;
- a minimal, redacted proof of concept.

If private reporting is unavailable, open a public issue that says only that you need a private security contact. Do not include technical details or attachments there.

You should receive an initial acknowledgement within seven days. Timing for validation, remediation, and disclosure depends on severity and whether coordination with Apple, Anthropic, OpenAI, or another upstream project is required.

## Release integrity

Official releases are expected to be Developer ID signed, notarized, stapled, and accompanied by `SHA256SUMS.txt`. The release workflow fails closed when signing or notarization credentials are unavailable. A Gatekeeper or checksum failure should be reported as a security issue; users should not be instructed to remove quarantine attributes to continue installation.

## Scope notes

Particularly relevant areas include host configuration preservation, shell-command construction, path traversal and symlink handling, atomic file replacement, receipt permissions, sound-pack parsing/import, code-signing/notarization, and release artifact provenance.
