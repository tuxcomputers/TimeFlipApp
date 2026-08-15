# Google OAuth: setting it up once, so nobody else has to

**Who this is for: whoever publishes the binary.** Today [configuration.md](configuration.md) asks every user to
create a Google Cloud project, configure a consent screen, mint an OAuth client and paste two strings into the app.
That is five steps of setup before the app does anything, and every one of them is a place to give up. This is what
replaces it: one project, owned by you, whose client ID ships inside the app.

**The app has not rebuilt the Google integration yet.** `google_account` and `time_entry.synced_to_google_calendar`
exist in the schema, the previous implementation is in `Archive/TimeFlipApp/Google*.swift`, and the sync itself was
never built even there (see [rebuild.md](rebuild.md), Backend). So Part 2 below is the shape of the work rather than a
description of what is in the app now. Part 1 can be done today, and should be, because the slow step in it is not
under your control.

**Google's console moves.** The tabs have been reorganised at least twice (this repo's own guide has been rewritten to
match), and scope classifications change. Where this doc names a click path, trust the intent over the wording, and
trust **the Sensitive/Restricted label the console shows against a scope** over anything written here about which tier
it is in.

---

## The decision that shapes everything: how many scopes you ask for

Verification effort scales with what you ask for, so decide this before touching the console.

The archive asks for six scopes (`Archive/TimeFlipApp/GoogleAuthConfiguration.swift`):

| Scope | What it buys | Tier |
| --- | --- | --- |
| `calendar.events` | Read and write events on any of the user's calendars | Sensitive |
| `calendar.readonly` | List the user's existing calendars, so one can be chosen | Sensitive |
| `calendar.app.created` | Create and manage a calendar **this app made**, and nothing else | Sensitive |
| `openid`, `userinfo.email`, `userinfo.profile` | The signed-in account's name and email, to show who is connected | Not sensitive |

The first two exist for one feature: **choosing an existing calendar to sync into**. Drop that feature, always create
and own a "TimeFlip" calendar, and the ask reduces to `calendar.app.created` plus the identity scopes. That is a
smaller consent screen, a shorter justification, and a much easier verification review. It costs the user the ability
to put TimeFlip events on a calendar they already share with somebody.

Decide it now, because changing the scope list after verification means going round again.

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
- **App name**: what the user will read in "TimeFlip macOS wants access to your Google Account". It must not imply
  Google made it.
- **Support email** and **developer contact**: these are public, and they are where consent-screen complaints land.
- **App logo**: needed for verification, and reviewed as part of it. A logo change later triggers re-review.

### 4. Add the scopes you settled on

**Data access > Add or remove scopes.** Add exactly the list from the decision above, and note the tier the console
puts against each one. That label, not this doc, is what decides whether step 6 applies.

### 5. Create the OAuth client

**Clients > Create OAuth client.** The type matters more than it looks:

- **iOS** (the console's description covers iOS, macOS and tvOS): keyed to your bundle identifier, and it issues **no
  client secret at all**. Redirects come back on a custom URI scheme (the reverse-DNS form of the bundle ID). This is
  the one to choose for a bundled binary, because it removes the question of what a "secret" means inside an
  application anybody can open.
- **Desktop app**: issues a client ID *and* a secret, and redirects to `http://127.0.0.1:<port>`. This is what the
  archive uses (`OIDRedirectHTTPHandler` in `GoogleAuthService.swift`). It is still legitimate to ship: Google's
  installed-app model explicitly does not treat that secret as confidential, and the security comes from PKCE plus the
  loopback redirect. But you are shipping a string called a secret that is not one, and explaining that to every
  future reader costs more than switching client type.

Either way, **the client ID is extractable from the binary**. That is accepted for installed apps and cannot be
prevented. What it means in practice: somebody could stand up a different application that shows your app's name on
its consent screen. PKCE stops them intercepting *your* users' codes; nothing stops the impersonation itself.

### 6. Publish, and get verified

**Two separate things, and the second is the long one.**

**Publish**: move the publishing status from Testing to **In production**. Testing is not a soft launch: it is capped
at 100 named test users, and refresh tokens issued under it **expire after seven days**, so every user would be
silently signed out weekly.

**Verify**: sensitive scopes in production require Google's OAuth app verification. Without it the app still works,
but every user meets a "Google hasn't verified this app" screen and must click through Advanced > Go to app, and you
are capped at roughly 100 users. What the submission needs:

- A **homepage** and a **privacy policy**, both on a domain you own
- **Domain ownership verified** in Search Console, under the account that owns the project
- The **app logo** from step 3
- A **demo video** showing the consent flow and each scope being used for the thing you said it was for
- A **written justification per scope**

Expect weeks, and expect at least one round of questions. The reviewer is checking that the scopes match the
demonstrated behaviour, which is the real reason to ask for as little as possible.

**What you do not need**: a third-party security assessment. That (CASA, annual, expensive) applies to *restricted*
scopes -- Gmail, full Drive. Calendar scopes are sensitive, one tier below, so verification is paperwork and a video
rather than an audit. Confirm against the console's own label before relying on it.

### 7. Know what you have taken on

- **Quota is yours.** Every user's API calls count against this project. Calendar's default ceiling is high enough
  that volume is not the concern; a single abusive user getting the project rate-limited or suspended is, because it
  takes everybody's sync down with it.
- **The support email is yours**, on the consent screen, in front of every user.
- **Re-verification** is triggered by changing the app name, the logo, the domains, or the scope list.

---

## Part 2: the app side

Written against the archive's implementation, which is where this code comes back from.

### 1. Ship the client ID as build configuration, not as a typed-in setting

The archive reads it from the environment (`GoogleAuthConfiguration.loadFromEnvironment`, `GOOGLE_OAUTH_CLIENT_ID`),
which works for a developer running from a shell and not at all for a user double-clicking an app. Put it in the
bundle instead: an `Info.plist` key filled from build configuration, read at launch.

Keep it out of the source tree the same way the JSON files already are (`.gitignore` line 8), and let the build inject
it. Not because the ID is a secret -- it is not -- but because a release build and a developer build should be able to
point at different projects without editing code.

### 2. Delete the paste-in fields, keep the override

The Client ID and Client Secret fields on the archive's Report tab go away: that is the whole point. **Keep the code
path behind them**, though, reading from `defaults`, an environment variable, or a hidden field:

- it lets you test against a second project without a release build,
- it gives a user with their own project a way out if yours is ever suspended,
- and it is what the developer-mode work already assumes exists.

### 3. Match the redirect to the client type

- **iOS-type client**: the redirect is a custom URI scheme, registered in `Info.plist` as a `CFBundleURLTypes` entry
  using the reverse-DNS client ID form. The app receives the callback through `application(_:open:)` and hands it to
  AppAuth. `OIDRedirectHTTPHandler` and its loopback listener are then dead code, and should go rather than linger.
- **Desktop-type client**: keep the loopback handler as it is, and carry the bundled secret through
  `GoogleAuthConfiguration.clientSecret`.

Either way PKCE stays on. AppAuth does it by default for the authorization-code flow, and it is the thing actually
protecting the exchange.

### 4. Leave the keychain alone

`GoogleOAuthKeychainStore` holds the auth state (refresh token) per user and per machine. That does not change: what
changes is that the *client secret* it also holds becomes either bundled configuration or nothing at all, depending on
client type. If you move to an iOS-type client, `GoogleClientSecretStore` and its keychain payload field go with it.

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

1. Decide the scope list (the section above).
2. Do Part 1 steps 1 to 5. Half a day at most.
3. Publish to production **unverified** and ship to a small group: it works immediately for about 100 users past a
   warning screen, which is enough to prove the flow while the rest runs.
4. Submit for verification, and expect it to be the long pole.
5. Build Part 2 against the project from step 2, with the override in place from the start.
