/* Two include directories are needed, not one: the arch-dependent `dbus-arch-deps.h` lives under
   /usr/lib/<triple>/dbus-1.0/include while the rest is in /usr/include/dbus-1.0. `pkgConfig: "dbus-1"`
   in Package.swift is what supplies both, which is why this includes by name rather than by path. */
#include <dbus/dbus.h>
