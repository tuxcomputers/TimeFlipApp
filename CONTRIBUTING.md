# Contributing

[← Back to README](README.md)

## Code Style

- Swift only, **4-space indentation**, and `swiftlint lint --quiet` clean. `.swiftlint.yml` is the authority:
  120-character lines (160 is an error), 600-line files, and comments and URLs exempt from both.
- **The decisions come out of the view.** Anything worth asserting -- what a click means, what a name collision
  implies, what to send a cube -- lives in a `...Rules` type taking values and answering with a value, so it can be
  tested without a window or a radio. `FacesTabRules`, `CategoryRenameRules`, `DeviceCommandRules` are the pattern.
- **Read from the database at the point of use.** This is the repo's first rule and it is not negotiable; see
  [CLAUDE.md](CLAUDE.md) for what it means and the one licensed exception.
- **Comments say why, not what.** The existing ones are long because they record what a decision cost -- a
  measurement against real hardware, a bug that shipped once. Match that rather than annotating syntax.
- Avoid over-engineering; keep solutions simple and focused.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes. **This repo does not use Conventional Commits**: a subject is an ordinary imperative
   sentence saying what the change does, in sentence case, with no `feat:`/`fix:` prefix. Recent examples:
   - `Keep a cube from stopping itself in the middle of a run`
   - `Send the auto-pause delay to the cube, and only offer it when there is one`
   - `Do not ask for a turn the cube has already made`

   The body is where detail belongs, and it is worth writing: reasoning that would otherwise go in a PR description
   stays attached to the code this way.
4. Push to your branch
5. Open a Pull Request with:
   - Purpose and motivation
   - Screenshots for UI changes
   - Documentation updates -- and if the change makes any existing doc wrong, fix it in the same PR

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

- Never commit Google credentials, API tokens, or device passwords. `.gitignore` covers
  `client_secret_*.json`, `config.*` and `Sources/FacetApp/Resources/google-client.json`; the OAuth client JSON
  belongs at `~/.config/facet/google-client.json`, outside the repository.
- `scripts/generate-credentials.sh` copies that file into the build so a distributed app can sign in. It runs from
  `scripts/run.sh` and from the scripted suite's build, and it exits 0 with nothing to copy -- **you do not need a
  Google project to build or test this repo.**
- The Google refresh token is the only thing in the macOS Keychain (`GoogleTokenStore`), one item, per user and per
  machine.
- The device PIN is in the Keychain, and in `~/Library/Application Support/Facet/config.json` only while the
  Keychain has refused a write. Neither is the database, deliberately: a database gets copied, switched between
  production and test, and rebuilt from the DDL by the test suite, and a cube does not know which one is in play --
  so a PIN kept in one is a PIN a database swap loses.

For build and test commands, see [Installation](docs/installation.md#building-and-testing).
