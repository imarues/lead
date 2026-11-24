import Foundation

// Builds a local promotion for Kira's channel using the real peer returned by
// Telegram, on the same account that requested help.getPromoData.
#if canImport(ObjectiveC)
@objc(LeadChannelPromotion)
#endif
final class LeadChannelPromotion: NSObject {
    static let username = "iKiraPlus"

    #if canImport(ObjectiveC)
    @objc
    #endif
    static func resolvePayload() -> NSData {
        let buffer = Buffer()
        // contacts.resolveUsername#725afbbc flags:# username:string referer:flags.0?string
        buffer.appendInt32(Int32(bitPattern: 0x725afbbc))
        buffer.appendInt32(0)
        serializeString(username, buffer: buffer, boxed: false)
        return buffer.makeData() as NSData
    }

    #if canImport(ObjectiveC)
    @objc(promoPayloadFromResolved:)
    #endif
    static func promoPayload(fromResolved bytes: NSData) -> NSData {
        let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
        let empty = Api.help.PromoData.promoDataEmpty(.init(expires: now + 120))
        var promo = empty
        if case let .resolvedPeer(resolved)? = Api.parse(Buffer(data: bytes as Data)) as? Api.contacts.ResolvedPeer,
           case let .peerChannel(peer) = resolved.peer {
            let channel = resolved.chats.first { chat in
                guard case let .channel(item) = chat,
                      item.id == peer.channelId, item.accessHash != nil,
                      item.flags & (1 << 5) != 0 else { return false }
                if item.username?.lowercased() == username.lowercased() { return true }
                return item.usernames?.contains { entry in
                    guard case let .username(value) = entry else { return false }
                    return value.username.lowercased() == username.lowercased() && value.flags & (1 << 1) != 0
                } ?? false
            }
            if let channel = channel {
                // Native additional chat-list item; no fake peer IDs, access hashes, joins or messages.
                // Mark as a local promotion via the existing proxy-style presentation.
                promo = .promoData(.init(flags: (1 << 0) | (1 << 3), expires: now + 1200,
                    peer: resolved.peer, psaType: nil, psaMessage: nil,
                    pendingSuggestions: [], dismissedSuggestions: [], customPendingSuggestion: nil,
                    chats: [channel], users: resolved.users))
            }
        }
        let out = Buffer()
        promo.serialize(out, true)
        return out.makeData() as NSData
    }
}
