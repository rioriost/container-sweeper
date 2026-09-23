# GUI implementation and verification — 2026-09-23

## Scope and design contract

Container Sweeper is a native macOS SwiftUI editor for scheduled cleanup. Keep profile selection in a standard sidebar, put schedule and action editing first, and keep Save & Apply and Run now visible while details scroll. Commands and operational help remain available through disclosures. Automatic changes still require applying settings; manual cleanup still requires confirmation. Preserve the cleanup engine, launchd registration semantics, destructive opt-ins, bilingual system-language selection, and deployment targets.

Baseline: `9ecb604`, initially clean working tree. Swift package and bundle minimum deployment version: macOS 14. The Container CLI and Homebrew Cask product requirement is macOS 26 and Apple Silicon, unchanged. Build/observed runtime: Xcode 27.0 (27A266a), macOS 27.0 (26A428), arm64. Apple's release feed retrieved on September 23 lists macOS 27.0 on September 14 as public and macOS 27.2 beta 2 on September 21 as prerelease. No prerelease-only UI API was adopted.

## Sources

Retrieved September 23, 2026. HIG text was read from Apple's DocC JSON using the skill's fetch helper; image/video portions were not used as textual evidence.

| Classification | Primary source | Applied guidance or API fact |
| --- | --- | --- |
| APPLE-HIG | [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | Resizable windows, comfortable density, discoverable menu commands and keyboard shortcuts. |
| APPLE-HIG | [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) | Familiar symbols and system navigation; avoid relying on the bottom of the sidebar for important actions. |
| APPLE-HIG | [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) | Specific action/context wording, meaningful cancellation, deliberate confirmation for irreversible operations. No default Return action was added to cleanup confirmations. |
| APPLE-HIG / ACCESSIBILITY | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | Semantic system controls and colors, explicit labels, text and symbols rather than color alone, keyboard access. |
| APPLE-SDK | [DatePicker](https://developer.apple.com/documentation/swiftui/datepicker) | Standard date/time input supporting hour-and-minute components; documented macOS availability starts at 10.15. |
| Release context | [Apple releases](https://developer.apple.com/news/releases/) | Public and prerelease channels kept separate from the tested environment. |

Spacing, grouping, and the smaller minimum window are implementation judgments, not claimed Apple numerical requirements.

## Changes and findings

| ID | Evidence and impact | Resolution |
| --- | --- | --- |
| GUI-01 | OBSERVATION: command listings and operational paragraphs occupied the same hierarchy as daily settings. | Concise action labels with contextual explanations; command/CLI/help disclosures; readable merged schedule summaries. Verified in Japanese and English. |
| GUI-02 | OBSERVATION: add/remove lived only below the sidebar; no profile command menu. | Toolbar Add and Profile Actions, File/Profile menus, Command-N, Command-S and Command-Shift-R. Verified keyboard and pointer interactions. |
| GUI-03 | OBSERVATION: separate hour/minute menus; invalid empty action sets still offered execution. | Standard time field; validation gates for Run/Apply; inline guidance. Test covers all 1,440 wall-clock minutes without DST/date conversion. |
| GUI-04 | OBSERVATION during implementation: native time AX value initially reflected an absolute date in the host timezone, and toggle AX descriptions omitted the short action names. | Explicit localized time accessibility value, switch names and hints. AX and time editing rechecked. This is not a VoiceOver execution claim. |
| GUI-05 | OBSERVATION during implementation: English split-view columns adopted an oversized ideal height, hiding the header/footer despite a bounded window. | Explicitly bound column heights to available geometry. Rechecked compact English/Japanese and empty state; footer remains visible. |
| GUI-06 | OBSERVATION: an empty list had no contextual action, and dismissed load failures left a disabled editor. | Actionable empty state and persistent load-error explanation. Load failure hides fallback profiles and prevents editing/applying. |
| GUI-07 | OBSERVATION: confirmation lacked selected profile context and used a generic title. | Operation-specific titles, profile name, human-readable actions, schedule for automatic changes, and exact commands. Escape cancels. |

## Verification

- **PASS** `make test`: 34 existing core tests, 5 new editor tests, 12 release-workflow tests (51 total). New tests exercise invalid/busy/empty gates, destructive confirmation, preview operation isolation, and all wall-clock minute round trips.
- **PASS** `make app`: release configuration builds, ad-hoc bundle signature verifies, English/Japanese resources load. Local artifact: `dist/Container Sweeper.app`.
- **PASS** Native runtime visual inspection: Japanese/dark and English/light; nominal 1000 × 780 default, minimum content 860 × 640 (the compact captured window including titlebar was 860 × 692). Tested selected daily/weekly profiles, merged schedules, destructive options, empty list, load error, progress and validation states. Forms scroll independently of the action footer.
- **PASS** Pointer/keyboard: Command-N adds/selects; name edits; Tab reaches the schedule switch and Space toggles it; time field arrow editing updates the profile and accessible value; Command-Shift-R opens confirmation; Escape cancels and returns to the editing context; Command-S opens destructive-save confirmation; removing a preview profile selects the remaining profile; empty-state Add creates a profile. Keyboard mode was `AppleKeyboardUIMode = 2`.
- **PASS** AX inspection: sidebar rows combine name/schedule/state; action switches expose name/value/hint; time exposes a matching localized value; invalid Run/Apply controls are disabled; progress exposes its status. Non-color labels distinguish saved/unsaved and manual/automatic states.
- **PASS** Destructive confirmation and cancellation were inspected in a debug fixture that blocks cleanup, schedule registration, browsing and other external operations. No real cleanup or schedule application was performed for UI verification.
- **NOT RUN** Actual VoiceOver speech, reading order and end-to-end task execution; Accessibility Inspector contrast audit; Increase Contrast/Reduce Transparency/Reduce Motion changes; text enlargement and a full keyboard-only end-to-end editing flow.
- **NOT RUN** macOS 14/26 runtime qualification. Compilation with a deployment target is not runtime evidence for those systems.
- **NOT RUN** Real cleanup, live launchd changes, notarization or publication. The release and engine unit suites retain their fake executors and isolated temporary homes.

The screenshot and AX observations are recorded in the associated Codex task. They are actual native windows, not drawn mockups.

## Reproduce the isolated previews

```sh
python3 scripts/preview-ui.py
python3 scripts/preview-ui.py --english --light --compact
python3 scripts/preview-ui.py --state merged
python3 scripts/preview-ui.py --state destructive --compact
python3 scripts/preview-ui.py --state empty
python3 scripts/preview-ui.py --state load-error
python3 scripts/preview-ui.py --state busy
```

Open the app path printed by the script. It builds a debug-only fixture with an independent bundle identifier and in-memory configuration. External operations are blocked by the model; edits are disposable. Preview arguments do not activate a preview in release builds.
