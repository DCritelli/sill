# The Mac Client compiles the iOS app's UIKit-free files where they are

The Mac Client's package target compiles the iOS app's UIKit-free client files (MessageReader, SessionLink, discovery and dial policies, SavedMacs, PointerPresence, MacMenuState, KeyChords and the like) where they are under `iOSClient/`, through symlinks in its own source folder. That is the convention VirtualDisplayProbe already uses for the Host's `VirtualDisplay.swift`, and simpler than a `sources:` list over a shared path. It has its own lean session controller instead of porting `StreamClient`. Moving those files into a shared library would be cleaner, but it would churn the iOS Xcode project. Porting `StreamClient` with `#if canImport(UIKit)` branches would tangle 4,100 lines of iOS code. Compiling in place leaves the iOS app untouched.

## Consequences

- An edit to one of those files must keep it free of UIKit, or the Mac Client stops building.
- If enough code ends up shared, this should become a proper library target that both apps link.
