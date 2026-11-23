import ActivityKit
import SwiftUI
import WidgetKit

// Must match the attributes embedded in the host's LeadDownloadLiveActivity.swift.
@available(iOSApplicationExtension 16.2, *)
struct LeadDownloadAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var fileName: String
        var received: Int64
        var total: Int64
    }
    var source: String
}

@available(iOSApplicationExtension 16.2, *)
private func percent(_ state: LeadDownloadAttributes.ContentState) -> Int? {
    guard state.total > 0 else { return nil }
    return min(100, Int(Double(state.received) * 100.0 / Double(state.total)))
}

@available(iOSApplicationExtension 16.2, *)
private func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, n), countStyle: .file)
}

@available(iOSApplicationExtension 16.2, *)
private struct LeadDownloadWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LeadDownloadAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.cyan)
                    Text(context.state.fileName).lineLimit(1)
                    Spacer(minLength: 4)
                    if let n = percent(context.state) { Text("\(n)%").monospacedDigit() }
                }
                ProgressView(value: Double(context.state.received),
                             total: Double(max(1, context.state.total)))
                    .tint(.cyan)
                    .opacity(context.state.total > 0 ? 1 : 0.25)
                HStack {
                    Text(bytes(context.state.received))
                    Spacer()
                    Text(context.state.total > 0 ? bytes(context.state.total) : "Downloading…")
                }
                .font(.caption2).foregroundColor(.secondary)
            }
            .padding(14)
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Telegram", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let n = percent(context.state) {
                        Text("\(n)%").monospacedDigit().font(.headline)
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.fileName).lineLimit(1).font(.subheadline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        if context.state.total > 0 {
                            ProgressView(value: Double(context.state.received),
                                         total: Double(context.state.total))
                                .tint(.cyan)
                        } else {
                            ProgressView().tint(.cyan)
                        }
                        HStack {
                            Text(bytes(context.state.received))
                            Spacer()
                            Text(context.state.total > 0 ? bytes(context.state.total) : "")
                        }.font(.caption2)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle")
            } compactTrailing: {
                Text(percent(context.state).map { "\($0)%" } ?? "…")
                    .font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: "arrow.down")
            }
        }
    }
}

@main
@available(iOSApplicationExtension 16.2, *)
struct LeadDownloadWidgetBundle: WidgetBundle {
    var body: some Widget {
        LeadDownloadWidget()
    }
}
