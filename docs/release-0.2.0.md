# Container Sweeper 0.2.0

A clearer native macOS interface and a new app icon.

- Reorganized profile editing with readable cleanup descriptions, expandable commands/CLI settings/help, and a persistent action bar.
- Native time input, localized time summaries, toolbar actions, and keyboard shortcuts: Command-N, Command-S, and Command-Shift-R.
- Improved empty/error states and cleanup confirmation; invalid action selections disable Run and Apply.
- New container-and-brush icon generated with gpt-image-2, packaged at macOS icon sizes and checked during release verification.
- Existing cleanup behavior and schedule storage remain unchanged. After upgrading, choose Save & Apply to refresh the installed helper and schedules.

Validation: 34 core tests, 5 editor tests, 13 release-workflow tests; Japanese/English runtime UI inspection and light/dark/compact-window checks. VoiceOver task execution and older macOS runtime qualification remain unverified. See [GUI review](gui-review-2026-09-23.md) for detailed coverage and [icon provenance](../output/imagegen/README.md).

Apple Silicon and macOS 26 or later are required for the Homebrew distribution and Apple Container CLI.
