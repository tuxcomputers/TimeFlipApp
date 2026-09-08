# Sending somebody a build

[← Back to README](../README.md) · [Installation →](installation.md)

`scripts/package.sh` builds a release `Facet.app` and wraps it in `dist/Facet-<version>.dmg`: the app,
an `Applications` shortcut to drag it onto, and a `Read Me First.txt` written for somebody who has
never seen it. The recipient needs no Swift, no Xcode and no Mint.

```bash
scripts/package.sh              # universal (arm64 + x86_64), the one to send
scripts/package.sh --arm64      # Apple Silicon only, faster, for a local check
```

It prints what went into the build rather than leaving it to be assumed: the version and commit, the
architectures, the signing identity, whether the Google client is in there, and the sha256 to quote
alongside the file.

## Gatekeeper is the whole of the problem

**Every build this repository can currently produce is refused on first launch by a machine that is
not this one.** The recipient sees macOS saying it cannot check the app for malicious software, and
has to go to System Settings > Privacy & Security and press *Open Anyway* once. That is what
`Read Me First.txt` walks them through, and it is the only thing standing between them and a working
app.

The cause is notarization, not signing. There are three tiers and this machine can reach the second:

| Signed with | `spctl --assess` | What the recipient sees |
| --- | --- | --- |
| Nothing (ad-hoc) | rejected | The refusal, plus a broken Keychain story across rebuilds |
| Apple Development | rejected | The refusal, once, cleared by hand |
| Developer ID, notarized and stapled | accepted | It just opens |

An Apple Development certificate is for running your own code on your own machines. It is worth
signing with anyway (`scripts/codesign-identity.sh` says why: an ad-hoc signature makes every build a
different application to the Keychain), but it buys nothing at all with Gatekeeper.

## Getting to the third row

Notarization needs a **Developer ID Application** certificate, which needs a paid Apple Developer
Program membership (99 USD a year). There is no free route: notarization is a service that only signs
off on builds from a paid team.

Once the certificate is in the login keychain, `scripts/package.sh` picks it up on its own
(`scripts/codesign-identity.sh` prefers `Developer ID Application` when both are present) and tells
you it can now be notarized. Two more steps then, and neither is in the script because neither has
been run here yet:

```bash
# Once: store an app-specific password from appleid.apple.com under a profile name.
xcrun notarytool store-credentials facet-notary \
    --apple-id apple@tux.com.au --team-id L8JM2BRRWT

# Per build: submit, wait for the verdict, then staple it into the image.
xcrun notarytool submit dist/Facet-1.0.dmg --keychain-profile facet-notary --wait
xcrun stapler staple dist/Facet-1.0.dmg
```

Stapling is what makes the ticket travel with the file, so the recipient's Mac does not need to reach
Apple to check it. Confirm the result with `spctl --assess --type open --context context:primary-signature -v`
against the image, and treat anything but `accepted` as not ready to send.

## What travels inside the build

- **The Google OAuth client**, copied in from `~/.config/facet/google-client.json` by
  `scripts/generate-credentials.sh` on every packaging run. Without it the app does everything except
  connect a Google account, and the script says so loudly rather than shipping a quiet gap. See
  [google-oauth-setup.md](google-oauth-setup.md).
- **Nothing else machine-specific.** No PIN, no database, no tokens. A fresh install creates
  `~/Library/Application Support/Facet/appdata.sqlite` from the bundled DDL on first launch.

**Check the OAuth consent screen's publishing status before sending a build to anybody who will sign
in.** While it is on *Testing* rather than *In production*, they have to be a named test user and
their refresh token expires after seven days, so sync stops working within a week and nothing on
screen explains why. That trap is written up in step 6 of [google-oauth-setup.md](google-oauth-setup.md).

## The icons are not yours to pass on

The activity icons are TimeFlip's, used here with permission granted to this project specifically.
That permission does not transfer with the code. Sending somebody a build of *this* app is covered;
a fork distributing its own build with these icons in it is not, and needs its own permission from
TimeFlip. See the licence note in the [README](../README.md).
