import ActivityKit
import SwiftUI
import WidgetKit

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
    return min(100, max(0, Int(Double(state.received) * 100 / Double(state.total))))
}

// Match Telegram's binary MB calculation rather than decimal SI bytes.
private func bytes(_ n: Int64) -> String {
    let mib = Double(max(0, n)) / 1_048_576
    if mib >= 1024 { return String(format: "%.2f GB", mib / 1024) }
    return String(format: "%.1f MB", mib)
}

@available(iOSApplicationExtension 16.2, *)
private struct DownloadDetails: View {
    let state: LeadDownloadAttributes.ContentState
    let showHeader: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.cyan)
                    Text(state.fileName).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(percent(state).map { "\($0)%" } ?? "…")
                        .monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
            } else {
                Text(state.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.total > 0 {
                ProgressView(value: Double(min(state.received, state.total)),
                             total: Double(state.total)).tint(.cyan)
            } else {
                ProgressView().tint(.cyan)
            }
            HStack {
                Text(bytes(state.received)).monospacedDigit().lineLimit(1)
                Spacer(minLength: 4)
                Text(bytes(state.total)).monospacedDigit().lineLimit(1)
            }.font(.caption2).foregroundColor(.secondary)
        }
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct LeadDownloadWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LeadDownloadAttributes.self) { context in
            DownloadDetails(state: context.state, showHeader: true)
                .padding(14)
                .activityBackgroundTint(.black.opacity(0.85))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.cyan)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state).map { "\($0)%" } ?? "…")
                        .monospacedDigit().lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DownloadDetails(state: context.state, showHeader: false)
                        .padding(.top, 3)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.cyan)
            } compactTrailing: {
                Text(percent(context.state).map { "\($0)%" } ?? "…")
                    .font(.caption2).monospacedDigit().lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } minimal: {
                Image(systemName: "arrow.down")
            }
        }
    }
}

@main
@available(iOSApplicationExtension 16.2, *)
struct LeadDownloadWidgetBundle: WidgetBundle {
    var body: some Widget { LeadDownloadWidget() }
}
