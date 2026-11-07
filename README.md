# Reclaim

A free, open-source disk clean-up app for macOS that explains where your space went in plain English and helps you get it back safely.

Reclaim is built on two rules:

- **It only looks until you say otherwise.** Nothing is removed without your approval.
- **Anything it removes is recoverable.** Files go to the Trash, photos go to Photos' Recently Deleted, and the Undo screen can put things back.

Nothing leaves your Mac. Reclaim makes no network requests and has no third-party dependencies. The written report uses Apple's on-device language model, which never sees file contents, only names and sizes.

## What it does

| Screen | What you get |
|---|---|
| **My Mac** | Whole-disk scan reconciled against APFS, so the totals match what macOS reports. Categories, purgeable space, Time Machine snapshots, and a written report. |
| **What's big** | An interactive space map of everything on the drive, or of any folder or external drive you choose. |
| **Clean up** | Plain-English suggestions with risk labels: caches, old downloads, developer leftovers, device backups, Homebrew packages nothing needs any more. |
| **Duplicates** | Exact duplicate files, hashed, with the best copy to keep preselected. |
| **Similar photos** | Near-identical photos in folders or in your Photos library, scored for sharpness and composition so the best shot is suggested. |
| **Photo clear-outs** | Screenshots, photos of text (receipts, notes), and burst extras, found with Apple's on-device recognisers. |
| **Uninstall apps** | Removes an app and its leftovers (caches, preferences, containers), with Homebrew awareness for cask-installed apps. |
| **Undo** | A log of everything Reclaim moved, with one-click restore. |

Homebrew commands (`cleanup`, `autoremove`, `uninstall --cask`) can be run from inside the app after confirmation. Anything that needs `sudo` is shown as text to copy into Terminal; Reclaim never runs it for you.

## Requirements

- macOS 15 (Sequoia) or later, Apple silicon
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- Apple Intelligence enabled, if you want the written report (otherwise a built-in writer is used)

## Install

```bash
git clone https://github.com/CavemanUK/reclaim.git
cd Reclaim
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

## How it stays safe

- `SafetyPolicy` is a deny-by-default allow-list. Your home folder, Documents, Library, Photos libraries, Music and iMovie libraries, `.ssh`, `.git` directories and the Trash itself are never offered for removal.
- Top-level folders on external drives are protected; you have to open the folder and choose what is inside.
- App leftovers are matched by exact bundle identifier, so uninstalling Chrome does not touch Chrome Canary's data.
- Every move is recorded in the action log (`~/Library/Application Support/Reclaim/history.json`) and in the unified log under the `actions` category.
- Files stored only in iCloud are skipped rather than downloaded.

## Project layout

```
Sources/Reclaim/
  Core/        scanning, classification, duplicate and photo analysis, safety policy, action log
  UI/          SwiftUI screens
  AppModel.swift, ReclaimApp.swift
Tests/ReclaimTests/
scripts/       build, install, test, icon generation, entitlements
docs/          feature ideas and roadmap
```

## Contributing

Issues and pull requests are welcome. Please keep to the two rules at the top: no removal without approval, and nothing unrecoverable.

## Licence

MIT. See [LICENSE](LICENSE).
