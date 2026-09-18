# The Rust port

[← Back to README](../README.md) · [Installation →](installation.md) · [Distribution →](distribution.md) · [TimeFlip BLE →](timeflip.md)

**The evaluation that decided Facet will be rewritten in Rust, and the requirements it was judged against.**
Written 2026-09-18. Nothing here has been built into the app: this is the record of a decision and of what was
established while making it, so that the work is not re-done when somebody picks it up.

**Every claim below is marked measured or untested.** Measured means it was run on this machine on the date
given. Untested means it comes from a vendor document, a crate's own platform notes or reasoning, and is
therefore a thing to confirm rather than a thing to build on. The distinction is the whole value of this file.

**The sequence is settled and the rewrite is not in flight.** The Linux port finishes in Swift first. The
conversion to Rust begins after it. That is a deliberate ordering, not a default: the Linux port is what
establishes the second platform's behaviour, and that knowledge is what the rewrite is then written against.

---

## The requirements

Stated by the owner, 2026-09-17 and 2026-09-18, and the thing every finding below is measured against.

1. **Three platforms**: macOS, Linux, and Windows. Windows is not yet started and is described as probable
   rather than certain, but it is a requirement of the language choice.
2. **The shipped app is completely self-contained.** The user installs no external programs, no runtime, no
   toolkit. **Build-time dependencies are unconstrained**: what it takes to develop the app does not matter.
3. **It looks, feels and operates the same on all three platforms, including the menu bar.**
4. **It does not need to look like a native Mac app.** This was stated explicitly after seeing the prototype,
   and it is what makes a single shared UI viable at all.
5. **The Linux target is MATE.** Not GNOME, not KDE. This narrows several answers below and improves one of
   them.
6. **The effort of changing language is not a constraint.**

Requirements 3 and 4 together are the unusual pair: uniformity matters, fidelity to any one platform does not.
That is the opposite of the priority the macOS app was built with, and it is why the conclusion differs from
the one the existing code implies.

---

## The decision, and the one fact behind it

**Rust, because of Bluetooth, not because of the UI.**

The expensive, error-prone, per-platform work in this app is the radio. macOS is CoreBluetooth, Linux is BlueZ
over D-Bus, and Windows would be a third implementation against WinRT. Every other concern (a window, a
database, an OAuth flow) has many cross-platform answers. The radio has almost none.

[`btleplug`](https://github.com/deviceplug/btleplug) is one async API over CoreBluetooth, BlueZ and WinRT,
host/central role only, no Bluetooth Classic, which is exactly this app's use. **Untested against the cube.**
It is the deciding factor and it is also the single largest unverified claim in this document. See *Open
questions*.

The rest of the stack follows without difficulty, all **untested**:

- `rusqlite` with the `bundled` feature compiles SQLite into the binary, so the schema and DDL carry over
  unchanged and nothing is installed on the user's machine.
- `tray-icon` gives a real `NSStatusItem`, `Shell_NotifyIcon` and StatusNotifierItem respectively.
- `keyring` covers Keychain, Windows Credential Manager and Secret Service.
- One self-contained binary per platform.

### What was rejected

**Qt, on Bluetooth.** Qt's own documentation records that the Windows Bluetooth LE backend can only find
devices **already paired through Windows Settings**, and does not supply RSSI or manufacturer-specific data.
Facet reconnects by scanning, so that limitation lands directly on the app's central mechanism. Rejected on
that alone, without reaching the UI question. **Untested**, from
[Qt Bluetooth](https://doc.qt.io/qt-6/qtbluetooth-index.html).

**Staying in Swift.** More viable than it was: a [Swift Windows workgroup formed in January
2026](https://www.swift.org/blog/announcing-windows-workgroup/) and Swift 6.3 expanded Windows support. But
there is no cross-platform BLE library and no cross-platform UI in that ecosystem, so Windows costs a third
radio and a third UI. It is the largest total effort of the options considered, and it is the path the project
is currently on.

**Python and Go.** `bleak` is a genuinely good cross-platform BLE library, but Python's self-contained
packaging conflicts with requirement 2 and its desktop UI story is weak. Go's BLE libraries are markedly less
mature than `btleplug` for the central role. Neither was pursued.

---

## The UI, measured

**A Slint prototype of the Settings window was built and run on this machine, 2026-09-18.** Five tabs, 640pt
wide, with every metric read out of `SettingsMetrics` rather than chosen, so that what was being compared was
the toolkit and not two people's taste in padding. Cupertino style, which is Slint's macOS imitation, chosen
so that any remaining difference is a real limit rather than a theme that was never trying.

**What transferred intact.** The layout rules survived: panels span the full tab width, the row rhythm reads
correctly, headings sit on their panel as the first row, and folds nest with their own defaults. Roughly 450
lines of markup reproduced the structure of the window faithfully. The `SettingsMetrics` work is portable.

**What did not.**

- **The tab bar.** Slint's `TabWidget` draws a full-width segmented strip welded to the top edge, where the
  app uses a centred pill group. That is the widget's structure rather than a theme setting, so matching it
  means reimplementing the tab bar.
- **Glyph fallback.** Category glyphs rendered as empty boxes. Slint performs its own font fallback and did
  not find them where AppKit would have. The real app uses SVG icons so this specific case does not arise, but
  it establishes that glyph fallback is now the toolkit's job and is weaker than the system's.
- **Controls are imitations.** The stepper is two chevron buttons rather than an `NSStepper`; pop-ups are
  bordered full-width fields rather than macOS pop-up buttons; primary buttons are a flat blue rather than the
  system accent treatment.
- **Type is heavier and larger** than AppKit at the same nominal size.
- **The window chrome is genuinely native** while its contents are not, so the seam sits at the window edge.

**Verdict against requirement 4: acceptable.** A Mac user would identify it as not a Mac app within seconds,
and that has been accepted.

### Styling is chosen at build time

**Untested**, from [Slint's documentation](https://docs.slint.dev/latest/docs/slint/reference/std-widgets/style/).
The widget style is fixed at compile time, not runtime. One build therefore looks identical on all three
platforms, which serves requirement 3 directly.

The `native` alias resolves per platform: `cupertino` on macOS, `fluent` on Windows, and on Linux `qt` **if Qt
is installed on the user's machine**, otherwise `fluent`. That Linux branch conflicts with requirement 2, so
Linux must pin an explicit style (`fluent` or `cosmic`) rather than letting `native` decide.

**The consequence worth holding on to:** choosing one style everywhere satisfies requirement 3 exactly.
Choosing `native` gives three appearances and partially abandons it. Given requirement 4, one style everywhere
is the right answer, and it is also the cheaper one.

---

## The menu bar

**This is the only part of the app where requirement 3 cannot be fully met, and the reason is the operating
systems rather than the language.** All figures below are **untested**, from
[`tray-icon`'s platform notes](https://docs.rs/tray-icon/latest/tray_icon/struct.TrayIcon.html) and
[its event documentation](https://docs.rs/tray-icon/latest/tray_icon/enum.TrayIconEvent.html).

The status item itself is native everywhere, because the OS owns that strip and nothing can draw its own. So
unlike the Settings window, the menu bar is the real thing on each platform rather than an imitation.

| | Left click | Right click | Text beside the icon |
|---|---|---|---|
| **macOS** | App's event | App's event | Yes |
| **Windows** | App's event | App's event | **Never** |
| **Linux, KSNI backend** | App's event | Host shows the menu, app never sees it | Yes, if an icon is set too |
| **Linux, AppIndicator backend** | **No event at all** | Host shows the menu | Yes, if an icon is set too |

Three consequences:

- **Windows can never show text in the tray.** `set_title` is documented "Windows: Unsupported", because
  `Shell_NotifyIcon` provides an icon and a hover tooltip and nothing else. The running category and elapsed
  clock cannot appear beside the icon there in any language. **The recommended answer is to put the elapsed
  time in the tooltip on Windows**, which is the nearest thing the platform offers.
- **Use the `ksni` backend on Linux, not `libappindicator`.** AppIndicator emits no click events whatsoever,
  which forecloses the design outright. `ksni` also drops GTK, `libxdo` and `libappindicator` as runtime
  dependencies, which serves requirement 2 at the same time.
- **On `ksni` the wanted shape falls out naturally.** Left click reaches the app, so pause and resume work;
  right click makes the host display the menu that was registered. The app does not need the right-click
  event, only the menu, and the host supplies it.

### MATE specifically

**Requirement 5 improves this answer, and MATE is the best Linux desktop for it.**

MATE's **Notification Area** applet implements *both* StatusNotifierItem over D-Bus *and* the legacy XEmbed
tray protocol. Most desktops dropped XEmbed, which is how they lost per-click control; MATE kept it. SNI
support is switchable through `org.mate.panel.enable-sni-support`.

The historical click bugs are largely closed: `mate-panel`
[#838](https://github.com/mate-desktop/mate-panel/issues/838) and
[#976](https://github.com/mate-desktop/mate-panel/issues/976) were closed in 2018 and 2019. The one still open,
[`mate-indicator-applet` #33](https://github.com/mate-desktop/mate-indicator-applet/issues/33), is a
**different applet**: the Indicator Applet, not the Notification Area.

**So left-click pause and right-click menu is plausible on MATE and unproven. UNTESTED, and it is the open
question that matters most.** A probe exists to settle it; see *Open questions*.

**The XEmbed route is closed from Rust.** It would guarantee full click control, but it needs `GtkStatusIcon`,
and [the GTK3 Rust bindings are unmaintained with RUSTSEC
advisories](https://fedoraproject.org/wiki/Changes/Retire_gtk3-rs,_gtk-rs-core_v0.18,_and_gtk4-rs_v0.7) while
GTK4 removed `StatusIcon` entirely. **Untested**, from those advisories.

### What requirement 3 actually gets

- **The Settings window**: identical on all three. Achievable.
- **The menu's contents and behaviour**: identical on all three. Achievable, provided the menu is the primary
  route to everything.
- **Left click as a shortcut**: macOS and Windows yes, MATE probably. Where it is unavailable the user loses a
  shortcut, not a capability.
- **Text beside the icon**: macOS and MATE yes, Windows never.

**The design rule that follows:** put Pause and Resume as the first item of the menu on every platform, and
treat left click as an accelerator for it rather than as the mechanism. Nothing may live behind left click
that has no menu equivalent, or Linux users lose a feature rather than a convenience.

---

## A finding that affects the current Swift Linux port

**This one matters before the rewrite, not after it**, which is why it is called out separately.

The Ayatana AppIndicator model is menu-only: it takes a menu and provides no click callbacks. **So the Linux
port as currently designed has the same left-click limitation described above**, and the divergence from the
macOS menu bar is already present rather than being something Rust would introduce.

**MATE supports XEmbed, and the Swift port already calls GTK3 through a modulemap**, so `gtk_status_icon_new`
and its `activate` and `popup-menu` signals are reachable from the existing code today. `GtkStatusIcon` is
deprecated in GTK3 and absent from GTK4, but MATE is a GTK3 desktop. **This is reasoning, not a measurement:
it has not been tried, and the deprecation makes it a route with a known end date.** It is recorded here
because the option is open now and closes when the app leaves Swift.

---

## Open questions

Each of these is a thing to run, not a thing to think about further.

1. **What MATE actually does with a left click.** A probe was written on 2026-09-18 that puts an icon, a title
   and a three-item menu in the tray and prints every event with its button and state. It uses the `ksni`
   backend and needs no GTK or libappindicator. It answers: does left click produce an event, does left click
   *also* open the menu (the old bug shape, which would spend the click whatever events arrive), does right
   click open the menu silently, and does the title text appear beside the icon. **Not yet run.**
2. **Whether `btleplug` can drive this cube.** Log in with the PIN, read a history frame, receive a face turn.
   The entire language recommendation rests on this and it has not been attempted. It is a few hours of work
   and it should happen before any rewrite is committed to, not after.
3. **The scripted suite's hold on the status item.** `MenuBarController` sets an accessibility identifier on
   the status item button, which is how `scripts/status-item-click.py` finds it. `tray-icon` exposes no
   equivalent API, so that script and every scripted check that presses the status item would need rewriting
   against whatever handle the Rust item does expose. Against a 32-script suite whose front door is the status
   item, this is a real line item.
4. **Editable tables in Slint.** The prototype is static. The real Categories and Faces tabs have editable
   cells, sorting, and rows driven by the database. A prototype flatters a toolkit; the cost arrives with live
   editing.

---

## The scratch work

Both were built on 2026-09-18, live outside this repository, and are **not committed**:

- `~/temp/facet-ui-prototype` -- the Slint Settings window, all five tabs, working tab bar and folds, no
  functionality behind anything.
- `~/temp/tray-probe` -- the MATE click probe described in open question 1, with a README listing what to
  watch for.

They are throwaways. What they established is recorded above, which is the part that has to survive them.
