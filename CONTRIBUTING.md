# Contributing

[← Back to README](README.md)

## Code Style

- Swift-only codebase with 2-space indentation
- Follow SwiftLint rules
- Small, testable functions with dependency injection
- Avoid over-engineering - keep solutions simple and focused

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes using [Conventional Commits](https://www.conventionalcommits.org/)
   - `feat: add calendar event deduplication`
   - `fix: handle device disconnect gracefully`
   - `docs: update Google OAuth setup instructions`
4. Push to your branch
5. Open a Pull Request with:
   - Purpose and motivation
   - Screenshots for UI changes
   - Documentation updates

## The scripted suite, and what happens if you have no TimeFlip

`swift test` is hermetic: it never opens a window and never touches a radio, so a change can be entirely
green there and broken the moment it runs. What says it works is `Tests/Scripted`, which drives the real
app against the real database, and some of it needs a TimeFlip in range and a person to turn it.

**CI cannot run any of that** -- no screen, no Keychain, no Google account, no cube. What it does instead is
refuse a pull request that has no record of a run: `Tests/Scripted/run.sh` writes `Tests/Scripted/last-run.md`
from the run it actually recorded, and that file is committed. It has to name this branch, name a commit in
this branch's history, report a run that passed with nothing failed and **nothing skipped**, and have been
run with a clean tree against the code as it now stands.

**If you have a TimeFlip**, run the suite and commit the stamp along with your change:

```sh
scripts/switch-database.sh test     # it refuses to run against your real data
Tests/Scripted/run.sh
```

**If you do not have one, open the pull request anyway.** The check will be red, and that is the honest
state of things rather than a hurdle to get around: your change has not been tried against hardware, and
saying so out loud is the whole point of the check. Nobody expects you to have bought a cube to fix a typo.

Say in the pull request that you could not run it. Somebody with a device then runs the suite against your
branch and commits the stamp, and the check goes green. Two things make that possible, so please leave both
alone:

- **Leave "Allow edits by maintainers" ticked** on your pull request. Without it there is no way to put the
  stamp on your branch, and the alternative is your work being re-opened as somebody else's pull request.
- **Do not rename or force-push the branch** while that is happening. The stamp names the branch and a
  commit, and a rewrite makes it evidence about code that no longer exists -- so the suite has to be run
  again, on hardware, by hand.

If you change the app again after the stamp lands, it goes stale and the suite has to be run again. That is
deliberate: editing a README does not force a re-run, changing anything under `Sources/`, `Tests/Scripted/`
or `database/` does.

## Security

- Never commit Google credentials, API tokens, or device passwords
- Credentials are stored in macOS Keychain

For build and test commands, see [Installation](docs/installation.md#building-and-testing).
