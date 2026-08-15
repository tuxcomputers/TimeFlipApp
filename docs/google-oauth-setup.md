# Google OAuth: setting it up once, so nobody else has to

**Who this is for: whoever publishes the binary.** Today [configuration.md](configuration.md) asks every user to
create a Google Cloud project, configure a consent screen, mint an OAuth client and paste two strings into the app.
That is five steps of setup before the app does anything, and every one of them is a place to give up. This is what
replaces it: one project, owned by you, whose client ID ships inside the app.

**The app has not rebuilt the Google integration yet.** `google_account` and `time_entry.synced_to_google_calendar`
exist in the schema, the previous implementation is in `Archive/TimeFlipApp/Google*.swift`, and the sync itself was
never built even there (see [rebuild.md](rebuild.md), Backend). So Part 2 below is the shape of the work rather than a
description of what is in the app now. Part 1 can be done today, and should be.

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

The archive asked for two more (`Archive/TimeFlipApp/GoogleAuthConfiguration.swift`), and **both are sensitive**:

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

> This repo already has two client-secret JSON files sitting untracked in `docs/` (`.gitignore` line 8 keeps them out
> of git), from projects `timeflipapp-macos` and `timeflip-agent`. Decide which of those is the real one, or make a
> third and retire both, before anything ships. Two half-configured projects is how the wrong client ID ends up in a
> release.

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
  `dev.evernoob.timeflip` to `au.com.tux.facet` would mean recreating the client. Under Desktop the rename and the
  Google setup do not block each other at all.
- **The archive already implements this flow.** `OIDRedirectHTTPHandler` in `GoogleAuthService.swift` is the loopback
  listener. The iOS path instead means a `CFBundleURLTypes` entry, an `application(_:open:)` handler, and deleting that
  code.
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

Written against the archive's implementation, which is where this code comes back from.

### 1. Ship the client ID and secret as build configuration, not as typed-in settings

The archive reads them from the environment (`GoogleAuthConfiguration.loadFromEnvironment`, `GOOGLE_OAUTH_CLIENT_ID`),
which works for a developer running from a shell and not at all for a user double-clicking an app. Put them in the
bundle instead: `Info.plist` keys filled from build configuration, read at launch. In this repo that means
`[apps.TimeFlip.plist]` in `Bundler.toml`.

Keep both out of the source tree the same way the JSON files already are (`.gitignore` line 8), and let the build
inject them. Not because either is confidential -- under a Desktop client neither is, see Part 1 step 5 -- but because
a release build and a developer build should be able to point at different projects without editing code.

### 2. Delete the paste-in fields, keep the override

The Client ID and Client Secret fields on the archive's Report tab go away: that is the whole point. **Keep the code
path behind them**, though, reading from `defaults`, an environment variable, or a hidden field:

- it lets you test against a second project without a release build,
- it gives a user with their own project a way out if yours is ever suspended,
- and it is what the developer-mode work already assumes exists.

### 3. Keep the loopback redirect

The client is a Desktop one, so the redirect is `http://127.0.0.1:<port>` and the archive's `OIDRedirectHTTPHandler`
comes back as it stands. No `CFBundleURLTypes` entry, no `application(_:open:)` handler, and no custom URI scheme
anywhere. The bundled secret is carried through `GoogleAuthConfiguration.clientSecret`.

**The port is chosen at runtime, never fixed.** `OIDRedirectHTTPHandler` binds an ephemeral one and builds the redirect
URI from what it got. A hardcoded port is a sign-in that fails whenever something else already holds it, and Google
accepts any port on the loopback address precisely so it does not have to be registered.

PKCE stays on. AppAuth does it by default for the authorization-code flow, and it is the thing actually protecting the
exchange.

### 4. Leave the keychain alone

`GoogleOAuthKeychainStore` holds the auth state (refresh token) per user and per machine, and that does not change.
What changes is `GoogleClientSecretStore`: the secret it holds is now bundled configuration rather than something the
user pasted in, so the store keeps its role as the override from step 2 rather than as the only source.

**The rename touches this.** Keychain items are keyed per application, so changing the bundle identifier from
`dev.evernoob.timeflip` to `au.com.tux.facet` orphans anything already stored. Harmless before release, since the fix
is signing in again, but it belongs in the rename's list rather than being discovered afterwards.

### 5. Handle the scope list changing under an existing user

A token issued before the scope list changed does not gain new scopes on its own. The archive's answer, and it is the
right one: sign out and sign in again, prompted by the app rather than discovered by the user when a sync fails.
`GoogleAuthConfiguration` already merges required scopes into whatever it was given, so the app can compare granted
scopes against required ones and say so.

### 6. Fail honestly when the project is the problem

A suspended project, a revoked client, or a quota ceiling all come back as an auth or API error rather than as
anything a user can act on. Say which it is, in words, and point at the override from step 2. Every one of these is
your problem and not theirs, and a message that pretends otherwise sends them to check their own network.

### 7. Rewrite the user-facing guide

[configuration.md](configuration.md) currently spends five steps and a screenshot on Google setup. Under this model
the user's whole flow is: open Settings, click **Sign in with Google**, choose an account, approve, done. Everything
above Step 5 in that document goes; what is worth keeping is the re-authentication note, because it is the one thing
that still bites.

---

## The order to do it in

1. ~~Decide the scope list~~. **Done**: the four non-sensitive scopes above.
2. Do Part 1 steps 1 to 5. Half a day at most.
3. Publish to production. With no sensitive scopes there is no verification queue to join and no warning screen to
   click past, so this is a setting rather than a submission.
4. Build Part 2 against the project from step 2, with the override in place from the start.

**There is no long pole any more.** The plan this document opened with had verification as the thing everything waited
on, which is why it advised shipping to a small group in the meantime. That is gone. The remaining work is all Part 2,
which is code, and code is the part you control.

**The TimeFlip to Facet rename does not gate any of this**, which is the practical dividend of the Desktop client:
nothing in the client is keyed to the app name or the bundle identifier, so steps 1 to 4 can happen before, during or
after the rename. The two places the rename does reach are the keychain (Part 2 step 4) and the consent screen's app
name, which should read `Facet` from the start rather than be changed later, since changing it re-triggers review.

**Do not submit for verification until the sync actually works.** Step 4 wants a video of each scope being used for the
purpose claimed, and there is nothing to film until Part 2 is built. The homepage and the privacy policy are live
already at `facet.tux.com.au` (`~/harry.git/facet_tux_com_au`), so the step 6 prerequisites are met and the
`facet-logo-120.png` in that repo is the consent screen logo.
