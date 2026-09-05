# Google OAuth: setting it up once, so nobody else has to

**Who this is for: whoever publishes the binary.** The previous app asked every user to create a Google Cloud project,
configure a consent screen, mint an OAuth client and paste two strings into the app. That is five steps of setup before
the app does anything, and every one of them is a place to give up. This is what replaced it: one project, owned by you,
whose client ID ships inside the app.

**Both halves are built.** Sign-in is `GoogleOAuthClient` (the loopback flow) over `GoogleOAuthRules` (the decisions),
and the sync itself is `CalendarSync`, which sweeps every unsynced `time_entry` and reads each event back before
ticking the row. The archive had neither: its OAuth went through AppAuth, and nothing there ever wrote
`synced_to_google_calendar`. The user-facing half, which is now one button, is documented at <https://facet.com.au>.

**Google's console moves, and it moved in our favour.** The tabs have been reorganised at least twice (this repo's own
guide has been rewritten to match), and scope classifications change: `calendar.app.created` was sensitive when this
document was first written and is non-sensitive now, which removed the verification process from the plan entirely.
Where this doc names a click path, trust the intent over the wording, and trust **the tier the console shows against a
scope** over anything written here about which tier it is in. That instruction has already earned its place once.

---

## The scope list, and why it turned out to be the whole ballgame

**Settled on 2026-08-15. All four scopes are non-sensitive**, confirmed against the console, which lists them under
"Your non-sensitive scopes":

| Scope | What it buys | Tier |
| --- | --- | --- |
| `openid` | Associate you with your personal info on Google | Non-sensitive |
| `userinfo.email` | The account's email address, to show who is connected | Non-sensitive |
| `userinfo.profile` | The account's name and picture, same purpose | Non-sensitive |
| `calendar.app.created` | Make secondary calendars, and manage events on the ones **this app made** | Non-sensitive |

The archive asked for two more (`GoogleAuthConfiguration.swift`), and **both are sensitive**:

| Scope | What it buys | Tier |
| --- | --- | --- |
| `calendar.events` | Read and write events on any of the user's calendars | Sensitive |
| `calendar.readonly` | List the user's existing calendars, so one can be chosen | Sensitive |

Those two exist for one feature: **choosing an existing calendar to sync into**. Dropping it, and always creating and
owning a "Facet" calendar, is what keeps the whole app inside the non-sensitive tier. It costs the user the ability to
put Facet events on a calendar they already share with somebody. **That single trade is worth more than everything else
in this document**, because it is the difference between publishing and being reviewed: see step 6.

`calendar.app.created` was itself classified sensitive until recently, and Google reclassified it. Two things follow.
**Trust the console's own label over this table**, since the classification is theirs to change and this file only
records what it said on the day. And **adding either sensitive scope back later is not a small change**: it moves the
app into the review process from a standing start.

---

## Part 1: the Google side

### 1. One project, owned by you

Google Cloud console, **New Project**. Name it for the product, not for a machine: the project name is not what users
see, but it is what you will be looking at in three years.

Own it from an account that will outlive the release, and one you can add a second owner to. If this project is lost,
every installed copy of the app loses its ability to sign in.

**Done: the project is `facet-505603`**, created 2026-08-15, with a Desktop OAuth client in it. Two earlier
half-configured projects (`timeflipapp-macos` and `timeflip-agent`) have been retired, which matters more than it
sounds: several projects that all nearly work is how the wrong client ID reaches a release.

**Its credentials live at `~/.config/facet/google-client.json`, outside every repo.** They were briefly in this repo's
`docs/`, ignored by `.gitignore` line 8 and never committed, but a documentation folder is one `git add -f` away from
publishing a credential and is a strange home for one regardless.

The file is the console's download unchanged. Its top-level key is `installed`, which is what confirms a Desktop client
rather than a web one, and the only two values the app needs from it are `client_id` and `client_secret`. The
`auth_uri` and `token_uri` beside them are Google's standard endpoints and should **not** be hardcoded: AppAuth reads
them from the discovery document, which is what survives Google moving one. `redirect_uris` says `http://localhost`,
which is a placeholder to ignore, since the loopback port is chosen at runtime (Part 2 step 3).

### 2. Enable the Calendar API

**APIs & Services > Library > Google Calendar API > Enable.** Nothing else. Every API enabled on the project is
another thing a reviewer asks about.

### 3. Fill in the consent screen properly

Under **Google Auth Platform** (formerly the OAuth consent screen wizard):

- **User type: External.** Internal only exists for a Google Workspace organisation, and it would mean only your own
  org's accounts could ever sign in. If that *is* the audience -- an internal tool for one company -- choose Internal
  and skip step 6 entirely, because verification does not apply.
- **App name: `Facet`.** This is what the user reads in "Facet wants access to your Google Account", so it has to match
  the name on the homepage, and it must not imply Google made it. Not to be confused with the OAuth *client* name in
  step 5, which is an internal label nobody outside the console sees.
- **Support email** and **developer contact**: these are public, and they are where consent-screen complaints land.
- **App logo: leave it empty.** This is the one field that costs something. Uploading a logo is by itself enough to
  put the app into the verification process, whatever the scopes are, so an app with none skips review entirely and one
  with a logo does not. See step 6. The artwork exists and is ready
  (`facet-logo-120.png` in `~/harry.git/facet_tux_com_au/public/images/`) for whenever that trade is worth making.

### 4. Add the scopes you settled on

**Data access > Add or remove scopes.** Add exactly the list from the decision above, and note the tier the console
puts against each one. That label, not this doc, is what decides whether step 6 applies.

### 5. Create the OAuth client

**Clients > Create OAuth client. Choose Desktop app.** Name it for the list you will be reading later rather than for
the product, since this name is internal to the console and never shown to a user: `Facet macOS (desktop)` beats
`Facet`. The name users read is the consent screen's **App name** from step 3, which is just `Facet`.

The console also offers an **iOS** type whose description covers macOS, and it is worth knowing why this app does not
take it. iOS clients issue **no client secret at all**, which sounds like the safer answer for a binary anybody can
open. Four things outweigh it here:

- **A Desktop client is not keyed to the bundle identifier.** An iOS client is, so renaming
  `au.com.tux.facet` to `au.com.tux.facet` would mean recreating the client. Under Desktop the rename and the
  Google setup do not block each other at all.
- **The loopback flow is what this app implements**, as `GoogleLoopbackListener` (the archive used AppAuth's
  `OIDRedirectHTTPHandler` in `GoogleAuthService.swift`). The iOS path would instead mean a
  `CFBundleURLTypes` entry and an `application(_:open:)` handler, neither of which exists.
- **This app is not sandboxed** (there is no entitlements file, and it ships outside the App Store via Swift Bundler),
  so listening on a loopback port costs nothing. A sandboxed build would need `com.apple.security.network.server`,
  which is the usual reason to prefer a custom scheme.
- **Custom URI schemes are weak on macOS specifically.** Any installed app can claim the same scheme in its
  `Info.plist` and Launch Services picks the winner. A port your own process is listening on is more predictable.

**The secret is not a secret, and neither type gives real client authentication.** Google's installed-app model
explicitly does not treat a desktop client secret as confidential, and a bundle identifier is equally forgeable for a
non-App-Store binary, since anybody can build an app claiming it. **PKCE** is what actually protects the exchange, and
AppAuth does it by default either way.

So: **the client ID and the secret are both extractable from the binary**, that is accepted for installed apps, and it
cannot be prevented. What it means in practice: somebody could stand up a different application that shows your app's
name on its consent screen. PKCE stops them intercepting *your* users' codes; nothing stops the impersonation itself.

**One thing to check on a real machine** rather than take on trust: whether the macOS application firewall prompts when
the app opens its loopback listener. It should not, since that firewall manages external interfaces and this binds
`127.0.0.1` only, but a firewall dialog in the middle of signing in is worth ruling out by seeing it not happen.

### 6. Publish

**This is now one step rather than two, because the scope list came out non-sensitive.**

**Publish**: move the publishing status from Testing to **In production**. Testing is not a soft launch: it is capped
at 100 named test users, and refresh tokens issued under it **expire after seven days**, so every user would be
silently signed out weekly. That expiry is the reason to move even while the app is only being tried out.

**Three things put an app into verification, and they are all yours to avoid.** The Push to production dialog states
them: a configuration with **more than 10 domains**, **a logo**, or **sensitive or restricted scopes**. Facet has one
domain and four non-sensitive scopes, so **the logo is the only one in play**, and leaving it unset is what keeps the
app out of review altogether.

**Verified is not a thing worth wanting on its own.** What verification removes is the "Google hasn't verified this
app" interstitial and the roughly 100 user ceiling, and both of those are consequences of asking for sensitive scopes
while unverified. Trip none of the three triggers and neither exists in the first place. So the choice is not
"verified or not", it is "logo or no review".

**What no logo costs**: the consent screen shows the app name without a custom icon. That is all. The recommendation
is therefore to publish with the logo field empty, and to add it later if the polish is wanted, at a moment when
nothing is waiting on the review.

**What still applies either way:**

- **The homepage and privacy policy** remain required fields on the consent screen, and remain a good idea regardless.
  They are already live at `facet.tux.com.au` (`~/harry.git/facet_tux_com_au`).
- **The 10 domain ceiling** is worth remembering rather than checking. One domain is a long way from it, but this is a
  trigger that could be tripped absent-mindedly.

**If the logo is ever added**, the review it triggers wants **domain ownership verified in Search Console under the
same Google account that owns the Cloud project**. That is the step that goes wrong quietly: verifying under one
account and creating the project under another leaves both looking complete and the submission rejected. The artwork
is `public/images/facet-logo-120.png` in the site repo, at the 120x120 the console asks for.

**What you never needed**: a third-party security assessment. That one (CASA, annual, expensive) applies to
*restricted* scopes, which are Gmail and full Drive. Nothing here comes close.

### 7. Know what you have taken on

- **Quota is yours.** Every user's API calls count against this project. Calendar's default ceiling is high enough
  that volume is not the concern; a single abusive user getting the project rate-limited or suspended is, because it
  takes everybody's sync down with it.
- **The support email is yours**, on the consent screen, in front of every user.
- **Three things move the app into verification, and nothing here is reviewed until one of them does**: a sensitive or
  restricted scope, a logo on the consent screen, or more than 10 domains. Adding `calendar.events` or
  `calendar.readonly` back, for the "sync into an existing calendar" feature, is the expensive one: video,
  justifications, weeks. Treat that feature as a decision with a price attached rather than as a later enhancement.
  Uploading a logo is the cheap one, and still a choice rather than a default.

---

## Part 2: the app side

**Built.** What follows says what each step came to.

### 1. Ship the client ID and secret with the build -- **done**

`GoogleCredentials.resolve` tries three sources in order: the `FACET_GOOGLE_CLIENT_JSON` environment variable, then
`~/.config/facet/google-client.json`, then what the build put in. The first two are files on one machine; **only the
third travels with the binary**, which is why it exists.

`scripts/generate-credentials.sh` is what fills it. It copies the console's download to
`Sources/FacetApp/Resources/google-client.json`, which is gitignored, so neither value is committed. Not because
either is confidential -- under a Desktop client neither is, see Part 1 step 5 -- but so a release build and a
developer build can point at different projects without editing code, and so the repo stays publishable without a
second thought. `scripts/run.sh` and the scripted suite's build both run it, so it is not a step anybody has to
remember.

**Copied verbatim rather than rewritten**, so the bundled resource and the two overrides are one format read by one
parser (`GoogleCredentials.fromJSON`) rather than two that can drift.

**A resource, not a generated Swift file, and the difference was measured.** The Swift-file version was built first:
a gitignored source file, with `Package.swift` checking whether it existed and defining `HAS_BUNDLED_CREDENTIALS`
when it did. **It fails silently.** SwiftPM caches the manifest, so the existence check does not re-run when the
generator creates the file: generator runs, `swift build` succeeds, define absent, credentials quietly not in the
binary, nothing anywhere saying so. `Package.swift` already `.process`es the whole `Resources` directory, and that is
a directory scan at build time rather than a manifest-time decision, so a file appearing there is picked up with no
cache to defeat. Confirmed both directions against a warm `.build`.

**No credentials is not an error.** A fork with no Google project builds and runs everything else; `resolve` answers
`nil` and the App tab says *"This copy of Facet was built without Google credentials, so it cannot sign in."* That is
also CI's case, so `swift build` needs no secret.

**Removing credentials prunes the build too.** SwiftPM does not delete a resource that has gone from the source
directory -- measured: delete it, `swift build`, and the copy under `.build/.../FacetApp_FacetApp.bundle/` is still
there -- and swift-bundler builds the `.app` from those products. So the generator clears them itself rather than
leaving a build carrying a client somebody has just taken away.

### 2. No paste-in fields, and the override kept -- **done**

There are no Client ID or Client Secret fields anywhere in the app: that was the whole point. The override survives as
the first two sources in step 1, and it earns its place for the reasons it always did -- it lets you test against a
second project without a release build, and it gives somebody a way out if the bundled project is ever suspended.

### 3. The loopback redirect -- **done, and not through AppAuth**

The client is a Desktop one, so the redirect is `http://127.0.0.1:<port>`. There is no `CFBundleURLTypes` entry, no
`application(_:open:)` handler and no custom URI scheme anywhere.

**`GoogleLoopbackListener` is this app's own**, over the Network framework, rather than AppAuth's
`OIDRedirectHTTPHandler`. `GoogleOAuthRules` records why: AppAuth is built around iOS view controllers and its macOS
loopback path is the least-exercised part of it, and the flow for an installed app is small enough that owning it is
cheaper than depending on it -- which also makes every decision in it ordinary Swift with tests on it. The package has
no dependencies at all as a result.

**The port is whatever the system gives, never fixed.** A hardcoded port is a sign-in that fails whenever something
else already holds it, and Google accepts any port on the loopback address precisely so it does not have to be
registered.

**PKCE is on** (`GoogleOAuthRules.pkce`): 32 random bytes base64url-encoded to a 43-character verifier, the shortest
RFC 7636 allows, with its S256 challenge. It is what actually protects the exchange, given that the client secret
ships inside the binary and is not a secret at all. A `state` value is echoed and checked too, so a redirect that did
not come from this process's own request can be told apart from one that did.

### 4. The Keychain -- **done, and it is one item**

`GoogleTokenStore` holds the refresh token in the login Keychain, per user and per machine, and nothing else goes
there: the client secret is configuration (step 1), not a stored credential, so there is no second store to keep.

**Codesigning is what makes it survive a rebuild**, and this cost a real debugging session. An ad-hoc signature's
designated requirement is the cdhash of the binary, so every build is a different application as far as the Keychain
is concerned and the permission granted to the last one matches nothing. A certificate makes the requirement stable
across builds, so "Always Allow" is answered once and holds. `scripts/codesign-identity.sh` finds an identity and
`scripts/run.sh` uses it; with none, the app is ad-hoc signed exactly as before and the only cost is the prompt. The
failure mode with no certificate is not an error: sync simply never runs (measured 2026-08-16, when a hand-run
`swift-bundler bundle` replaced a signed build and the scripted checks found the sweep silent).

### 5. The scope list changing under an existing user -- **not applicable as written**

A token issued before the scope list changed does not gain new scopes on its own, and the answer is still sign out and
sign in again. It matters less than it did: the list is the four in the table above and has not moved since, and
dropping the two sensitive scopes is what fixed the case this step was written for.

### 6. Fail honestly when the project is the problem -- **done**

A suspended project, a revoked client or a quota ceiling all come back as an auth or API error rather than as anything
a user can act on. `GoogleCalendarRules` names them in words, including the one that is easiest to misread -- the
Keychain refusing to hand over the token, which is **not** the same as not being signed in.

### 7. The user-facing guide -- **done**

The user documentation's Google section is now one button and a note about what the four scopes buy.

---

## The order to do it in

1. ~~Decide the scope list~~. **Done**: the four non-sensitive scopes above.
2. ~~Build the app side~~. **Done except Part 2 step 1**: sign-in, the loopback flow, PKCE, the token store and the
   calendar sweep are all built and have run against a real account.
3. Do Part 1 steps 1 to 5, on the project that will be the published one. Half a day at most.
4. **Part 2 step 1**: get the pair from that project into the built bundle. Until this is done there is no such thing
   as a distributable build -- the app resolves credentials from a file on the developer's own machine.
5. Publish to production. With no sensitive scopes there is no verification queue to join and no warning screen to
   click past, so this is a setting rather than a submission.

**There is no long pole any more.** The plan this document opened with had verification as the thing everything waited
on, which is why it advised shipping to a small group in the meantime. That is gone, and so is most of Part 2.

**The rename does not gate any of this**, which is the practical dividend of the Desktop client: nothing in the client
is keyed to the app name or the bundle identifier. The one place it does reach is the consent screen's app name, which
should read `Facet` from the start rather than be changed later, since changing it re-triggers review.

The homepage and the privacy policy are live already at `facet.tux.com.au` (`~/harry.git/facet_tux_com_au`), and the
`facet-logo-120.png` in that repo is the consent screen logo.

---

## Why macOS asks for Keychain access after every rebuild

The refresh token lives in the login Keychain (`GoogleTokenStore`), and the Keychain grants access to *an
application*, identified by its code signature. **For an ad-hoc signed build that identity is the cdhash of the
binary**, so every rebuild is a different application as far as the Keychain is concerned. Clicking **Always Allow**
works exactly as advertised; it just records permission for a binary that no longer exists after the next build.

A real certificate changes what the permission is recorded against. The designated requirement becomes

```
identifier "au.com.tux.facet" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: ..."
```

with no hash in it, so it is the same for every build and the answer holds.

**The setup, once:**

1. Xcode -> Settings -> Accounts -> add your Apple ID (a free account is enough), select it, **Manage
   Certificates...** -> **+** -> **Apple Development**.
2. Check it is usable: `security find-identity -v -p codesigning` must list it.
3. Run the app through `scripts/run.sh`, which finds the identity and signs with it. Answer **Always Allow** to the
   one prompt that follows, because the identity has changed one last time.

**If step 2 says `0 valid identities found` while Xcode clearly shows the certificate**, the chain cannot be built and
the certificate is therefore not a usable identity. Measured on 2026-08-15: the only WWDR intermediate installed was
the original one, which **expired on 2023-02-07**, while the certificate itself is issued by WWDR **G3**. Apple Root
CA was present; the middle link was not. The fix is to install the current intermediate, after which the identity
appears immediately:

```sh
curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db
```

The symptom this produces is misleading, which is why it is written down: `codesign` reports `unable to build chain to
self-signed root` followed by `errSecInternalComponent`, which reads like a broken certificate or a permissions
problem rather than a missing intermediate.

**A contributor with no certificate loses nothing but the prompt.** `scripts/run.sh` falls back to an ad-hoc build and
says so.
