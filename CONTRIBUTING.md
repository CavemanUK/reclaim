# Contributing to Reclaim

Thanks for taking a look. Reclaim moves people's files, so contributions are held to a high bar on safety and a friendly bar on everything else.

## Ground rules

These two rules are not negotiable; a pull request that breaks either will not be merged:

1. **Nothing is removed without the user's explicit approval**, shown as the exact list of items.
2. **Nothing Reclaim removes is unrecoverable.** Files go to the Trash, photos to Recently Deleted, and the action is recorded so Undo works. (The documented exceptions need the user's explicit choice: Homebrew commands, and "Delete permanently…" on the Undo screen for items Reclaim itself trashed.)

Also:

- No network requests and no third-party dependencies. If you think you need one, open an issue first.
- Nothing runs `sudo`. Commands that need it are shown as text to copy.
- New code that can remove or move files must be reachable only through `ActionLog` and checked by `SafetyPolicy`.

## Getting started

```bash
git clone https://github.com/CavemanUK/reclaim.git
cd reclaim
./scripts/test.sh          # run the tests (needs only the Xcode Command Line Tools)
./scripts/install.sh       # build, sign and install ~/Applications/Reclaim.app
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. It explains the layout, the data flow, the safety model and the concurrency helpers, and has recipes for the common changes (a new clean-up suggestion, a new screen, a new safety rule).

macOS needs Full Disk Access and Photos permission to be granted to the *installed app*, so some behaviour can only be checked by running `Reclaim.app`, not from a terminal. The architecture guide explains how to run the headless diagnostics as the app.

## Making a change

1. Open an issue first for anything bigger than a bug fix, so we can agree on the approach.
2. Keep the change focused. One feature or fix per pull request.
3. **Write tests for logic.** Anything in `Core/` that decides what to show, match, rank or remove needs a test in `Tests/ReclaimTests/`. Safety changes need tests for both what is now allowed and the neighbours that must stay blocked.
4. Run `./scripts/test.sh`; everything must pass.
5. Try the change in the real app. Describe what you did in the pull request; screenshots help for UI.

## Code style

- **Comment for the next reader.** Every type, protocol and non-trivial function gets a `///` doc comment saying what it is *for*. Inside functions, comment the *why* (a safety reason, a macOS quirk, an ordering constraint), not what the code literally says. Each file starts with a short comment on its purpose.
- British English in comments and user-facing text.
- Plain language in the UI. Say what will happen, how much space it frees and how to undo it. Avoid jargon (write "hidden", not "APFS purgeable gap").
- Prefer small value types in `Core/` that can be tested without a window. Keep SwiftUI views free of business logic; put actions in `AppModel`.
- Be honest in the UI. If a figure is an upper bound, say "up to". If something couldn't be measured, say so instead of showing zero.
- Follow the existing page layout: start a screen with `ScreenHeader` and wrap its body in `.pageBody()`.

## Pull request checklist

- [ ] Both ground rules still hold
- [ ] Tests added or updated, and `./scripts/test.sh` passes
- [ ] New code is commented as described above
- [ ] README or `docs/` updated if behaviour changed
- [ ] No new dependencies, network calls or `sudo`

## Reporting problems

Open an issue with your macOS version, what you did, and what happened. For anything that **moved or removed something it shouldn't have**, say so in the title and include what you can from the Undo screen or the log:

```bash
log show --last 1h --predicate 'subsystem == "app.reclaim.mac"'
```

## AI-assisted contributions

This project was itself written with AI assistance, so AI-assisted pull requests are welcome. You are responsible for what you submit: run the tests, try the change in the app, and make sure you understand it.

## Licence

By contributing you agree that your contribution is released under the project's [MIT licence](LICENSE).
