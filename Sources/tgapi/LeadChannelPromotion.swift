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

    private static func sponsor(_ bytes: NSData) -> Api.help.PromoData.Cons_promoData? {
        guard case let .promoData(data)? = Api.parse(Buffer(data: bytes as Data)) as? Api.help.PromoData,
              data.flags & 1 != 0, data.psaType == nil, data.psaMessage == nil,
              case .peerChannel? = data.peer else { return nil }
        return data
    }

    @objc static func containsSponsor(_ bytes: NSData) -> Bool {
        return sponsor(bytes) != nil
    }

    @objc(replaceSponsor:resolved:)
    static func replaceSponsor(_ bytes: NSData, resolved: NSData) -> NSData? {
        guard let data = sponsor(bytes),
              case let .resolvedPeer(value)? = Api.parse(Buffer(data: resolved as Data)) as? Api.contacts.ResolvedPeer,
              case let .peerChannel(peer) = value.peer,
              let chat = value.chats.first(where: {
                  guard case let .channel(channel) = $0 else { return false }
                  return channel.id == peer.channelId && channel.accessHash != nil && channel.flags & (1 << 5) != 0
              }) else { return nil }

        data.peer = value.peer
        data.chats.removeAll {
            if case let .channel(channel) = $0 { return channel.id == peer.channelId }
            return false
        }
        data.chats.append(chat)
        let out = Buffer()
        Api.help.PromoData.promoData(data).serialize(out, true)
        return out.makeData() as NSData
    }
}
