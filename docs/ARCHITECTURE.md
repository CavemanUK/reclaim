# Architecture

A tour of how Reclaim is put together, written for someone who wants to change it. For what the app does, see the [README](../README.md); for how to submit a change, see [CONTRIBUTING](../CONTRIBUTING.md).

## The two rules everything is built around

1. **Reclaim only looks until the user approves.** Scanning, analysis and previews never change anything. Every change goes through a confirmation sheet that lists the exact items.
2. **Anything Reclaim removes is recoverable.** Files go to the Trash, photos go to Photos' Recently Deleted, "keep in iCloud only" can be downloaded again, and the Undo screen can reverse it. Two things are deliberately not undoable, and both need the user's explicit choice: a Homebrew command (Homebrew's own operation), and **Delete permanently…** on the Undo screen, which removes only items Reclaim itself moved to the Trash, behind a confirmation. `ActionLog.purge` refuses any path that isn't inside a recognised Trash.

If a change would break either rule, it does not belong in this app.

## Layout

```
Sources/Reclaim/
  ReclaimApp.swift      app entry, window, sidebar, shared sheets, developer diagnostics (CLIScan)
  AppModel.swift        the one observable object every screen reads (state + actions)
  Core/                 no SwiftUI: scanning, analysis, safety, the action log
  UI/                   SwiftUI screens and shared components
Tests/ReclaimTests/     Swift Testing suites for the Core logic
scripts/                build_app.sh, install.sh, test.sh, icon, entitlements
docs/                   this file, feature ideas
```

`Core/` never imports SwiftUI (a few files use AppKit or Photos). That keeps the logic testable without a window and makes the dependency direction clear: `UI` and `AppModel` depend on `Core`, never the reverse.

## How data flows

```
 DiskScanner ──► FileNode tree ──► SpaceClassifier ──► SpaceReport ─┐
 (read-only)     (pruned sizes)    (category per path)  (+ APFS facts)│
                       │                                            ▼
                       └──────────► InsightEngine ──► [Insight] ──► AppModel ──► SwiftUI views
                                    (clean-up cards)                    ▲
 DuplicateFinder / SimilarPhotoFinder / PhotoClearoutFinder / AppInventory ─┘
                                                                        │
 user approves ──► TrashRequest ──► ActionLog (the only code that changes files) ──► HistoryEntry ──► Undo
```

- **`DiskScanner`** walks the disk and builds a `FileNode` tree. It measures *allocated* size (what really occupies the disk), ignores symlinks, stays on the Data volume's device, and prunes small files and folders into a "rolled up" total so a whole-disk scan stays light on memory.
- **`SpaceClassifier`** assigns every path to a `SpaceCategory` (Applications, Caches, Developer tools…). Category totals add up exactly to the scanned bytes; a test enforces this.
- **`SpaceReport`** combines the scan with the APFS facts from `SystemInfo` (container size, per-volume use, snapshots) and computes the "hidden" gap: space macOS says is in use that no file accounts for.
- **`InsightEngine`** turns the tree into the cards on the Clean up screen. Each card is a `Spot` (a known location with an explanation and a risk label) or a hand-written finder (project dependencies, old installers, large files, iCloud local copies).
- **`AppModel`** holds all state and exposes actions. Views read it through the SwiftUI environment and call its methods; they contain no business logic.

## Concurrency

Everything slow runs off the main thread, and the helpers in `Core/Concurrency.swift` are the only sanctioned ways to do it:

| Helper | Use it for |
|---|---|
| `runBlocking` | One blocking job (a directory walk, a hash, a subprocess) from async code. Runs on a global dispatch queue so it never ties up Swift's cooperative thread pool. |
| `concurrentMap` | Many independent blocking jobs, bounded width, in order. File hashing, thumbnails. |
| `concurrentMapAsync` | Many jobs whose work is itself `async` (Vision's async requests). |
| `blockingParallelMap` | Blocking work that must **not** run on the cooperative pool. Vision feature prints: issuing them from a saturated cooperative pool stalls on Vision's internal queue, which hung scans before this helper existed. Call it from inside `runBlocking`. |
| `CancelFlag` | Cooperative cancellation shared with the UI's Stop buttons. Long loops check it. |

Rules of thumb: never block the main actor; never call `NSAppleScript` or semaphore-wait on the main thread; throttle progress callbacks (every N items) because each one hops to the main actor.

## The safety model

All file changes happen in **one place**, `ActionLog`, and every path through it is checked first by `SafetyPolicy`.

- **`SafetyPolicy` is a deny-list inside your home folder and drives, and a refusal everywhere else.** Anything outside the home folder and `/Volumes` is refused outright. Inside them, a path is allowed unless it is protected: top-level folders, credentials, `.git`, app bundles, Photos/Music/iMovie/Final Cut libraries, Time Machine data, or anything already in a Trash. `~/Library` is the exception and works as an allow-list: only caches, logs, developer folders and device backups may be removed, everything else there is refused. Because most of the home folder is allowed by default, a new protected location must be added to the deny rules, with a test.
- **Uninstalling** uses a narrower exception, `verdict(forPath:uninstalling:)`: only the app bundle and entries in a fixed list of `~/Library` folders whose names match the app by exact bundle identifier (or exact app name, excluding generic names like "Music"). Another installed app's identifier that merely *extends* this one's (Chrome vs Chrome Canary) is never claimed. System-protected (SIP) apps are never offered.
- **Trashing** tries `trashItem`; if macOS refuses for permission reasons it retries with a file-coordinated move into `~/.Trash`. That fallback exists because plain `trashItem` fails with error 513 on iCloud-synced Desktop and Documents files that another app created, while a coordinated move succeeds. Next come `NSWorkspace.recycle` and, for protected app bundles only, a Finder request. Restore uses the same coordinated move.
- **Photos** deletion goes through PhotoKit, which shows its own confirmation and keeps items in Recently Deleted.
- **"Keep in iCloud only"** calls `evictUbiquitousItem` and only for items confirmed to be in iCloud *and* fully uploaded.
- **Homebrew** commands go through `BrewCommand.parse`, an allow-list of three subcommands with a strict character check, and run as an argument array (never through a shell).
- **Nothing runs `sudo`.** Commands that need it are shown as text to copy.

Every change is a `HistoryEntry` saved to `~/Library/Application Support/Reclaim/history.json` (and logged to the unified log, category `actions`). `ActionLog.reconcile()` brings the record in line with what the user did in Finder since.

## The analysis pipelines

**Duplicates** (`DuplicateFinder`): group by size, then a 16 KB head-and-tail hash, then a full SHA-256. Hard links are collapsed (deleting one frees nothing). iCloud-only (dataless) files are skipped because reading one would download it.

**Similar photos** (`SimilarPhotoFinder`) works on any `PhotoSource` (folders via `FileSource`, the Photos library via `LibrarySource`):

1. a 64-bit perceptual hash of every photo's thumbnail;
2. candidate pairs by Hamming distance (cheap, O(n²) bit operations);
3. Apple's Vision feature prints confirm each candidate pair (this is what stops different photos being grouped);
4. byte-identical copies are folded into one representative, because exact copies belong to the Duplicates screen;
5. each remaining photo is scored (sharpness, Apple's aesthetics model, face capture quality, resolution, bytes per pixel) and the best is suggested, with a plain-language reason.

For library photos the real byte size is unknown unless the original is local, so a size of 0 means "unknown", never "empty".

**Photo clear-outs** (`PhotoClearoutFinder`): screenshots and unpicked burst frames come straight from Photos' own metadata; "text and readings" uses Vision's text recogniser and image classifier.

**Over time** (`Core/ScanHistory.swift`): each whole-disk scan becomes a small `ScanRecord` (totals, bytes per category, the ~40 biggest folders); `ScanComparison` diffs two of them. Separately, `DrivePoint`s record free space at most every six hours so the chart has a timeline between scans. Stored in `trend.json`.

**Report** (`Core/AIReport.swift`): scan results are reduced to short factual lines (`ReportFacts`) and given to Apple's on-device model with strict instructions. If Apple Intelligence isn't available, a built-in writer produces the same three sections from the same facts. The model never sees file contents.

## Building, signing and permissions

Reclaim builds with Swift Package Manager and the Command Line Tools only, then `scripts/build_app.sh` wraps the binary into `Reclaim.app`, writes `Info.plist` and signs it.

- It is signed with a self-signed identity called **Reclaim Dev** (`install.sh` creates it). macOS keys privacy permissions (Full Disk Access, Photos) to the app's code signature; an ad-hoc signature changes on every build and silently loses the grants, so a stable identity matters.
- `scripts/Reclaim.entitlements` declares Photos and Apple Events access. Without the Photos entitlement, a hardened-runtime app is refused the permission prompt entirely.
- Avoid Apple SwiftUI overlay types that misbehave in CLT-only builds. `VideoPlayer` crashed at launch (replaced by an AppKit `AVPlayerView` wrapper), so the chart in Over time is drawn with `Canvas` rather than Swift Charts.

## Testing

```bash
./scripts/test.sh        # the whole suite, CLT-only friendly
```

Tests cover the logic in `Core/`: the safety policy and uninstall matching, the duplicate finder (including traps: same-size files, matching head and tail, hard links), the action log (reconcile, purge guard, error classification), photo ranking, treemap layout, Homebrew command parsing, scan history maths and chart geometry. UI is not unit-tested; it is checked by running the app.

**Developer diagnostics.** The binary can run headless checks that exit without opening a window, but only with `RECLAIM_DEV=1` in the environment:

```bash
RECLAIM_DEV=1 .build/debug/Reclaim --scan ~/Pictures        # totals, compare with du
RECLAIM_DEV=1 .build/debug/Reclaim --dups /some/folder
RECLAIM_DEV=1 .build/debug/Reclaim --photos /some/folder balanced
RECLAIM_DEV=1 .build/debug/Reclaim --trend-check            # real scan through the Over time pipeline
```

macOS privacy permissions belong to the *app*, not your shell. To test something that depends on them (the Photos library, trashing iCloud files, Full Disk Access), run the diagnostic as the installed app and have it write a report file:

```bash
open -n -W --env RECLAIM_DEV=1 ~/Applications/Reclaim.app --args --library /tmp/out.txt balanced
```

## Where state lives

| What | Where |
|---|---|
| Undo log | `~/Library/Application Support/Reclaim/history.json` |
| Over time history | `~/Library/Application Support/Reclaim/trend.json` |
| Added scan folders | `UserDefaults` (`customFolders`) |
| First-run flag | `UserDefaults` (`hasSeenWelcome`) |

Nothing is sent anywhere. Reclaim's own code makes no network requests.

## Recipes

**Add a clean-up suggestion.** Add a `Spot` to `InsightEngine.spots` (path relative to home, title, plain-English summary, risk, and either `.children` mode to list removable sub-folders or `.whole` for a folder with an explanation or command). Mark `partial: true` if the figure is an upper bound. If the action is a Homebrew command, put it in `command:` and the card gets a Run button automatically.

**Add a screen.** Add a case to `SidebarItem` (title, icon, colour), a view in `UI/` that starts with `ScreenHeader` and wraps its content in `.pageBody()` so margins match, a case in `ContentView`'s switch, and put any state and actions in `AppModel`.

**Change what may be removed.** Edit `SafetyPolicy`, and add a test in `SafetyPolicyTests` for both the new allow and the neighbours that must stay blocked. Safety changes without tests will not be accepted.

**Add a developer diagnostic.** Add a function to `CLIScan` and dispatch it in `ReclaimApp.init` behind the `RECLAIM_DEV` check.

## Gotchas learned the hard way

- iCloud placeholders ("dataless" files) report an allocated size of 0, and reading them triggers a download. Check `Imaging.isCloudOnly` before opening anything in synced folders.
- `~/Library/Application Support/Google/Chrome` and similar vendor folders hold several products. Match inside the vendor folder per product, never the whole folder.
- A bulk text replace once turned `refreshVolume()`'s own body into a call to itself. Search for self-recursion after mechanical edits.
- `.build` caches absolute paths. If the project folder moves, delete `.build`.
- Test time-dependent logic with a pinned clock; a test that depends on the current time of day will fail near midnight.
