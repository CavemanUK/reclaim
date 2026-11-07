# Reclaim

A free, open-source disk clean-up app for macOS that explains where your space went in plain English and helps you get it back safely.

Reclaim is built on two rules:

- **It only looks until you say otherwise.** Nothing is removed without your approval.
- **Anything Reclaim removes is recoverable.** Files go to the Trash, photos go to Photos' Recently Deleted, local copies of iCloud files can be downloaded again, and the Undo screen can put things back. Two things are deliberately not undoable: Homebrew commands you choose to run (Homebrew's own operations, below), and the **Delete permanently…** button on the Undo screen, which removes only items Reclaim itself moved to the Trash, after a confirmation.

Nothing leaves your Mac. Reclaim's own code makes no network requests and has no third-party dependencies. The written report uses Apple's on-device language model, which never sees file contents, only names and sizes.

## What it does

| Screen | What you get |
|---|---|
| **My Mac** | Whole-disk scan reconciled against APFS, so the totals match what macOS reports. Categories, purgeable space, Time Machine snapshots, and a written report. |
| **What's big** | An interactive space map of everything on the drive, or of any folder or external drive you choose. |
| **Over time** | Every whole-disk scan is remembered, with a free-space chart and a comparison: which categories and folders grew or shrank since the previous scan, a week ago, or the first scan, and how much Reclaim itself freed in between. Stored only on your Mac, with a Clear history button. |
| **Clean up** | Plain-English suggestions with risk labels: caches, old downloads, developer leftovers, device backups, Homebrew packages nothing needs any more, and "Keep in iCloud only" for files already safe in iCloud (frees the local copy without deleting anything). |
| **Duplicates** | Exact duplicate files, hashed, with the best copy to keep suggested. Nothing is marked for removal until you choose. |
| **Similar photos** | Near-identical photos in folders or in your Photos library, scored for sharpness and composition so the best shot is suggested. |
| **Photo clear-outs** | Screenshots, photos of text (receipts, notes), and burst extras, found with Apple's on-device recognisers. |
| **Uninstall apps** | Removes an app and its leftovers (caches, preferences, containers), with Homebrew awareness for cask-installed apps. |
| **Undo** | A log of everything Reclaim moved, with one-click restore. |

Every change goes through an approval sheet that lists the exact items first. The Homebrew sheet also has a **Preview** button, which runs Homebrew's own `--dry-run` because those commands can't be undone.

Homebrew commands (`cleanup`, `autoremove`, `uninstall --cask`) can be run from inside the app after you confirm the exact command. They are Homebrew's own operations, so unlike everything else in Reclaim they cannot be undone from the Undo screen. Anything that needs `sudo` is shown as text to copy into Terminal; Reclaim never runs it for you.

## Requirements

- macOS 15 (Sequoia) or later, Apple silicon
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- Apple Intelligence enabled, if you want the written report (otherwise a built-in writer is used)

## Install

```bash
git clone https://github.com/CavemanUK/reclaim.git
cd reclaim
./scripts/install.sh
```

The install script:

1. Checks the Swift toolchain is present.
2. Creates a self-signed code-signing certificate called **Reclaim Dev** in your login keychain. macOS will ask for your password once. This is so that Full Disk Access and Photos permissions survive rebuilds; an ad-hoc signature changes on every build and macOS silently drops the grants each time. If you would rather not add a certificate, run `./scripts/build_app.sh` instead and the app is signed ad hoc.
3. Builds the app, installs it to `~/Applications/Reclaim.app`, and opens it.

Then, in **System Settings › Privacy & Security**:

- **Full Disk Access** → add Reclaim. Without it, Mail, Messages, Safari data and some system folders are invisible and the "hidden" figure on My Mac will be larger.
- **Photos** → Reclaim appears after the first library search. Allow Full Access so it can move photos to Recently Deleted.
- **Automation** → macOS will prompt the first time Reclaim asks Finder to trash an app it protects.

## Build and test by hand

```bash
./scripts/build_app.sh   # builds Reclaim.app in the project folder and ~/Applications
./scripts/test.sh        # runs the test suite with only the Command Line Tools
```

The test script passes extra flags because Swift Testing lives in the Command Line Tools' extra Frameworks folder. If you have full Xcode, plain `swift test` also works.

## Developer flags

The release binary contains a few diagnostics used by the test workflow: read-only scan, duplicate and photo checks, plus three that touch a file you name or create a throwaway one (`--trash-file`, `--selftest-trash`, `--evict-test`). They are off unless `RECLAIM_DEV=1` is set in the environment, so launching the app normally can never reach them:

```bash
RECLAIM_DEV=1 ~/Applications/Reclaim.app/Contents/MacOS/Reclaim --scan ~/Pictures
```

## How it stays safe

- `SafetyPolicy` refuses everything outside your home folder and mounted drives. Inside them it protects named places: your home folder and its top-level folders (Documents, Desktop…), `.ssh` and other credentials, `.git` directories, app bundles, Photos, Music, iMovie and Final Cut libraries, Time Machine data, and the Trash itself. `~/Library` is the other way round: only caches, logs, developer folders and device backups are allowed, and everything else there is refused.
- Top-level folders on external drives are protected; you have to open the folder and choose what is inside.
- App leftovers are matched by exact bundle identifier, so uninstalling Chrome does not touch Chrome Canary's data.
- Every move is recorded in the action log (`~/Library/Application Support/Reclaim/history.json`) and in the unified log under the `actions` category.
- Your choices on the Duplicates and Similar photos screens (folders, minimum size, photo source, strictness) are remembered in the app's preferences, along with any scan folders you add. Scan results and ticked selections are never saved.
- The Over time history (`trend.json`, same folder) holds only totals, per-category sizes and the names and sizes of your largest folders. It never leaves your Mac and can be cleared from the Over time screen.
- Files stored only in iCloud are skipped rather than downloaded.

## Project layout

```
Sources/Reclaim/
  Core/        scanning, classification, duplicate and photo analysis, safety policy, action log, scan history
  UI/          SwiftUI screens
  AppModel.swift, ReclaimApp.swift
Tests/ReclaimTests/
scripts/       build, install, test, icon generation, entitlements
docs/          ARCHITECTURE.md (how it fits together), FEATURE-IDEAS.md (roadmap)
```

New to the code? Start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): it explains the data flow, the safety model, the concurrency helpers, and how to add a suggestion, a screen or a safety rule.

## How it was made

Reclaim was written with AI assistance: the code was produced by Anthropic's Claude (through Claude Code), directed, run and tested by its maintainer on a real Mac. It has a test suite and deliberately conservative safety rules, but it is still a tool that moves files. Read the approval screens, keep backups, and treat it as you would any new software that touches your data.

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and keep to the two rules at the top: no removal without approval, and nothing unrecoverable.

## Licence

MIT. See [LICENSE](LICENSE).
