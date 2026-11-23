import Foundation
import ActivityKit

// The companion WidgetKit extension must be embedded in the signed IPA.
// A dylib alone cannot draw the Dynamic Island.
@available(iOS 16.2, *)
struct LeadDownloadAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var fileName: String
        var received: Int64
        var total: Int64
    }
    var source: String
}

@objc(LeadDownloadActivityBridge)
final class LeadDownloadActivityBridge: NSObject {
    @available(iOS 16.2, *)
    private static var current: Activity<LeadDownloadAttributes>?
    private static var lastUpdate: TimeInterval = 0
    private static var lastToken = ""

    @objc(updateWithName:received:total:)
    static func update(name: String, received: NSNumber, total: NSNumber) {
        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let done = !name.isEmpty && total.int64Value > 0 && received.int64Value >= total.int64Value
        let isEmpty = name.isEmpty
        let now = Date().timeIntervalSince1970
        if !done && !isEmpty && now - lastUpdate < 1.2 { return }
        lastUpdate = now
        let state = LeadDownloadAttributes.ContentState(
            fileName: String(name.prefix(120)),
            received: max(0, received.int64Value),
            total: max(0, total.int64Value))
        Task { @MainActor in
            if isEmpty || done {
                if let activity = current {
                    await activity.end(ActivityContent(state: state, staleDate: nil),
                                       dismissalPolicy: .default)
                    current = nil
                }
                return
            }
            if let activity = current {
                await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(35)))
            } else {
                do {
                    current = try Activity<LeadDownloadAttributes>.request(
                        attributes: LeadDownloadAttributes(source: "Telegram"),
                        content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(35)),
                        pushType: nil)
                } catch {
                    NSLog("[LeadDownload] Live Activity unavailable: %@", String(describing: error))
                }
            }
        }
    }
}
