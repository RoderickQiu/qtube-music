import Foundation
import QTInnerTube

// Owner: data-layer builder (M3). See docs/architecture.md › QTAuth.
//
// Planned contents: Google sign-in in a WKWebView (accounts.google.com → music.youtube.com), cookies kept in the
// Keychain, brand accounts (`onBehalfOfUser`), session-loss handling, and a DEBUG-only "Import session" path
// (HANDOFF.md §8). Writing to the user's account is gated: ask the user first.

/// Signed-in state as the UI sees it.
public enum QTAuthState: Sendable, Hashable {
    case signedOut
    case signingIn
    case signedIn(accountName: String, isPremium: Bool)
    case sessionExpired
}
