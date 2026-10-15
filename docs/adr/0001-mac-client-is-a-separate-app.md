# The Mac Client is a separate app, not part of Sill.app

The Mac Client ships as its own macOS app, working name Sill Client, built from the same Swift package as Sill.app, rather than as a "Connect to a Mac…" window inside Sill.app. Sill.app is a menu-bar-only Host that needs Screen Recording and Accessibility. The Mac Client needs a Dock icon and normal windows, and none of those permissions. Keeping the two roles in separate apps keeps each app's permissions, lifecycle and UI simple.

## Consequences

- A Mac that is both a Host and a Device runs two apps.
- The name must not be "Sill Viewer", which an unofficial third-party project (upstream issue #109) already uses.
