# Reclaim — where it could go next

Written 6 November 2026, after the first full day of use. Everything below respects the two rules the app is built on: Reclaim only *looks* until you say otherwise, and anything it removes is recoverable (Trash, Photos' Recently Deleted).

Effort: **S** = an hour or two, **M** = half a day, **L** = a day or more.

## What's there today

Whole-disk scan with honest reconciliation against APFS · space map · plain-English clean-up suggestions with risk labels · exact duplicates · near-identical photos (folders and Photos library) with best-pick scoring · photo clear-outs (screenshots, text, bursts) · app uninstaller with leftovers and Homebrew awareness · Homebrew commands run in-app after confirmation · Undo with reconciliation · a written report from Apple's on-device model.

## Highest value next

1. **"Keep in iCloud only" for files (M).** Your Desktop and Documents sync with iCloud. macOS can evict a file's local copy while keeping it in iCloud (`brctl evict`, the same thing as Finder's *Remove Download*). This frees space *without deleting anything*, which is exactly Reclaim's philosophy. Offer it on big files and folders in What's big and Clean up, with a "Download again" path. It also sidesteps the iCloud-Desktop trash refusal we hit (error 513).

2. **One-off admin elevation instead of a root helper (M).** The three things that need `sudo` on your Mac — thinning Time Machine snapshots, rebuilding the Spotlight index, erasing system logs — can be run through macOS's own administrator password dialog (`osascript … with administrator privileges`) with no daemon left behind. Reclaim would show the exact command, you'd confirm in Reclaim, then macOS asks for your password. Same shape as the Homebrew sheet. This is the honest middle ground between "copy this into Terminal" and a permanent root helper.

3. **Space over time — done.** The *Over time* screen keeps every whole-disk scan, charts free space, and compares any two scans by category and by folder, including how much Reclaim itself freed in between. A one-line trend sits on My Mac and in the written report. Possible follow-ups: category badges on My Mac, a menu-bar warning when free space drops, and notes when a folder has grown for several scans in a row.

4. **A holding area instead of the Trash (L).** Items Reclaim removes go into its own dated folder and are deleted for good after 30 days unless restored — Photos' *Recently Deleted* model, for files. Space is only freed when the holding period ends or you choose "free now", but Undo becomes trivially reliable and nothing can be lost by emptying the Trash in Finder by habit. The Undo screen already has most of the UI.

5. **Permissions wizard on first run (S).** Full Disk Access, Photos, Automation: one screen with live status for each, what it unlocks, and a Fix button. Today each screen explains its own permission; a single place with green ticks would remove most of the confusion we hit.

## Photos

- **Shaky, blurry and accidental shots (S).** The sharpness and composition scores already exist; add a clear-out collection for photos that are badly blurred, nearly black or nearly white (pocket photos). Show them in a grid, nothing pre-ticked.
- **Videos by size and screen recordings (S).** Photos tags screen recordings; videos are the biggest items in most libraries. Add both as clear-out collections.
- **Live Photo video halves and RAW+JPEG pairs (M).** Each Live Photo carries a short video; each RAW has a JPEG twin. Offer to drop the halves the user never looks at, via PhotoKit so Photos stays consistent.
- **Duplicates inside the Photos library (M).** Photos has its own Duplicates album; Reclaim could read it and offer bulk merge through PhotoKit.

## Files and developer

- **Duplicate folders (M).** Whole-folder duplicates (copied project folders, exported bundles) are common and invisible to a file-level finder. Hash folder manifests, not just files.
- **Old and unopened files (S).** "Your biggest files" exists; add *not opened in over a year* using Spotlight's last-used date, which the app inventory already reads.
- **Developer caches, properly (M).** Per-project Xcode DerivedData, simulator runtimes via `xcrun simctl list -j`, Docker images and build cache via the Docker CLI, pip/conda/yarn/pnpm caches, `~/.cache`. Same allow-listed runner as Homebrew, so Reclaim can run `docker system prune` and `xcrun simctl delete unavailable` after confirmation.
- **Empty the Trash from Reclaim (S).** Ask Finder to do it (it already asks Finder to move protected apps). Confirmation sheet first, obviously.
- **Document version history (S).** `.DocumentRevisions-V100` is a prime suspect for your hidden 31 GB. With the elevation above, measure it; macOS prunes it on its own, so this is information, not an action.

## Trust and safety

- ~~**Dry run.**~~ Done for Homebrew only (a Preview button running `--dry-run`). The other approval sheets already list every item and can be undone, so a second preview was removed to keep the app simple. (Original idea: A "show me what would happen" toggle on every approval sheet that lists the exact moves and does nothing. Cheap and reassuring.)
- **Per-item "don't suggest again"** and an exclusions list (folders Reclaim should never look in).
- **Activity log in the app.** The unified log already records every move; surface it under Undo.

## Polish and distribution

- ~~**Persist settings (S):**~~ Done for the duplicate and photo folders, minimum size, photo source and strictness. Sort orders are not saved yet.
- **Keyboard and VoiceOver pass (M):** labels on the toggles and map tiles, arrow-key navigation in the map.
- **Export the report (S):** copy or save as Markdown/PDF from the report card.
- **Menu bar extra (M):** free space at a glance, "scan now", a warning when free space drops under a threshold you set.
- **Developer ID signing and notarisation (M, needs an Apple Developer account):** needed only if Reclaim ever leaves this Mac. The current self-signed identity is fine for personal use and keeps permissions stable across rebuilds.
- **Update mechanism (M):** Sparkle, if distributed.

## Explicitly not recommended

- **A permanent root helper** — bypasses the Trash and Undo for everything it touches; the one-off elevation above covers the real needs.
- **Stripping localisations or CPU architectures from apps** — breaks code signatures on notarised apps; the "cleaner" tools that did this have largely stopped.
- **"RAM cleaning", DNS flushing, maintenance scripts** — free no disk space.

## Known rough edges to fix regardless

- ~~iCloud Desktop/Documents refused `trashItem` (error 513)~~ Fixed: a file-coordinated move into `~/.Trash` is now used when the plain trash is refused.
- Syncthing index growth (ignore patterns for `node_modules`, `.venv`, `.build`).
- The report's "usage profile" is inferred from sizes and app usage; it should also learn from what you actually keep and remove.
