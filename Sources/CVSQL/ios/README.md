# iOS headers

The C that V generates for Apple platforms includes three headers that the iOS
SDK doesn't have (or that are an error on iOS). These take their place, on
iOS only (see `cSettings` in `Package.swift`). They can be removed once vsql's
amalgamation leaves out those includes for iOS.

Every function that libvsql calls is in the iOS libSystem.
