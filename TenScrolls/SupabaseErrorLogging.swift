import Foundation

/// Logs an actor-call failure, except when `error` is just a
/// `CancellationError`. Most of the calls that use this
/// (`SupabaseMessaging`, `SupabaseSharing`) run inside a SwiftUI
/// `.task(id:)` — see `CaravanView`'s task keyed on
/// `"\(friendCodes.joined())-\(traderCode)"` — which legitimately cancels
/// whatever's still in flight the instant its id changes (e.g. right after
/// `addFriend` appends a code, before that same task's own
/// `syncFriendLinks()` loop finishes). The new task instance re-runs
/// immediately with the updated state, so the call isn't lost, just
/// superseded — logging that as "⚠️ ... failed" reads like a real problem
/// when it's actually just self-inflicted, expected churn.
///
/// A `CancellationError` reaching one of these catch blocks always means
/// "superseded," never "the request failed for a reason worth knowing
/// about" — so it's dropped here rather than logged, not merely quieted.
func logSupabaseFailure(_ context: @autoclosure () -> String, _ error: Error) {
    guard !(error is CancellationError) else { return }
    print("\u{26A0}\u{FE0F} \(context()): \(error)")
}
