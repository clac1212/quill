# ADR-001 :: Multiplatform repository

Last updated: `2026.08.01`

> Keep Quill as one product repository with symmetric platform implementation
> roots. Share behavioral contracts and fixtures across the platforms, but let
> each native implementation own its source and build graph.

## 1. Decision

- Keep macOS, Windows, and Linux in the existing Quill repository.
- Place each native implementation under a platform-named root.
- Keep platform build systems independent.
- Share session and transcript contracts, compatibility fixtures, product
  documentation, and release coordination at the repository root.
- Expose stable root scripts for common developer workflows.

## 2. Rationale

Quill has one product identity and one output contract, but each operating
system has different audio, lifecycle, interface, packaging, and inference
APIs. A cross-platform application framework would not remove the
platform-specific work in the recording path. Sharing application source would
therefore add an abstraction boundary without eliminating the difficult native
code.

Separate repositories were rejected because schema, fixture, documentation,
and product changes would need coordinated pull requests and could drift.
Leaving macOS at the root and adding other platform directories beside it was
also rejected: it would encode one platform as the implicit default and make
the repository less legible as additional native work appears.

The tradeoff is that source-based macOS builds now run from `macos/`. Installed
macOS binaries are unaffected, and root scripts provide a stable replacement
workflow.

## 3. Design Implications

- Platform source must not import code across platform roots.
- Cross-platform compatibility belongs in schemas and fixtures, not duplicated
  language-specific models presented as shared code.
- CI and release packaging run independently per platform.
- Root documentation describes the product; platform READMEs describe native
  installation, permissions, configuration, and troubleshooting.
- New platform roots require their own explicit feasibility decision rather
  than inheriting assumptions from macOS or Windows.

## 4. When to Revisit

Reconsider this structure if Quill adopts a shared runtime that eliminates a
material amount of native code, platform releases acquire independent owners
or product identities, or coordination overhead inside the monorepo becomes
greater than contract drift across separate repositories.
