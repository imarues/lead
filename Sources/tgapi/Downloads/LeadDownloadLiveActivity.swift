import Foundation
import ActivityKit

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
    private enum Event {
        case progress(LeadDownloadAttributes.ContentState)
        case idle
    }

    @available(iOS 16.2, *)
    @MainActor private static var current: Activity<LeadDownloadAttributes>?
    @available(iOS 16.2, *)
    @MainActor private static var pending: Event?
    @available(iOS 16.2, *)
    @MainActor private static var lastSent: LeadDownloadAttributes.ContentState?
    @MainActor private static var draining = false
    @MainActor private static var lastWrite: TimeInterval = 0

    @objc(updateWithName:received:total:)
    static func update(name: String, received: NSNumber, total: NSNumber) {
        guard #available(iOS 16.2, *) else { return }
        let size = max(0, total.int64Value)
        let downloaded = max(0, received.int64Value)
        let state = LeadDownloadAttributes.ContentState(
            fileName: String(name.prefix(120)),
            received: size > 0 ? min(size, downloaded) : downloaded,
            total: size)
        Task { @MainActor in
            enqueue(name.isEmpty ? .idle : .progress(state))
        }
    }

    @available(iOS 16.2, *)
    @MainActor private static func enqueue(_ event: Event) {
        // Latest-wins trailing queue. Unlike the old early return, a throttled
        // final chunk always remains pending until ActivityKit receives it.
        pending = event
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            await drain()
        }
    }

    @available(iOS 16.2, *)
    @MainActor private static func drain() async {
        while pending != nil {
            let elapsed = ProcessInfo.processInfo.systemUptime - lastWrite
            if elapsed < 1.0 {
                try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
            }
            // Read only after sleeping, to send the newest real byte count.
            guard let event = pending else { break }
            pending = nil
            await publish(event)
        }
        draining = false
    }

    @available(iOS 16.2, *)
    @MainActor private static func publish(_ event: Event) async {
        switch event {
        case .idle:
            if let activity = current {
                if let state = lastSent {
                    await activity.end(ActivityContent(state: state, staleDate: nil),
                                       dismissalPolicy: .immediate)
                } else {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                current = nil
            }
            lastSent = nil
        case .progress(let state):
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            if let activity = current,
               activity.activityState == .ended || activity.activityState == .dismissed {
                current = nil
                lastSent = nil
            }
            if state == lastSent && current != nil { return }
            let finished = state.total > 0 && state.received >= state.total
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(45))
            if let activity = current {
                await activity.update(content)
                lastSent = state
                lastWrite = ProcessInfo.processInfo.systemUptime
                if finished {
                    await activity.end(ActivityContent(state: state, staleDate: nil),
                                       dismissalPolicy: .after(Date().addingTimeInterval(5)))
                    current = nil
                }
            } else if !finished {
                do {
                    current = try Activity<LeadDownloadAttributes>.request(
                        attributes: LeadDownloadAttributes(source: "Telegram"),
                        content: content, pushType: nil)
                    lastSent = state
                    lastWrite = ProcessInfo.processInfo.systemUptime
                } catch {
                    NSLog("[LeadDownload] Live Activity unavailable: %@", String(describing: error))
                    lastWrite = ProcessInfo.processInfo.systemUptime
                }
            }
        }
    }
}
