/* The one header, reached through the include path rather than by absolute path: `pkgConfig: "sqlite3"`
   in Package.swift is what supplies it, so a machine with the library somewhere other than /usr/include
   (a distro that moves it, or Homebrew) needs nothing changed here. */
#include <sqlite3.h>
