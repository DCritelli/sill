# The Mac Client compiles the iOS app's UIKit-free files where they are

The Mac Client's package target lists the iOS app's UIKit-free client files (MessageReader, SessionLink, discovery and dial policies, SavedMacs, PointerPresence, MacMenuState, KeyChords and the like) in its `sources:` list, compiling them in place under `iOSClient/`. It has its own lean session controller instead of porting `StreamClient`. Moving those files into a shared library would be cleaner, but it would churn the iOS Xcode project. Porting `StreamClient` with `#if canImport(UIKit)` branches would tangle 4,100 lines of iOS code. Compiling in place leaves the iOS app untouched.

## Consequences

- An edit to one of those files must keep it free of UIKit, or the Mac Client stops building.
- If enough code ends up shared, this should become a proper library target that both apps link.
