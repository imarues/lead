// Decode Telegram's own dialogs response using Lead's generated TL schema.
// Only the peer display name and same-session InputPeer are exposed to the picker.
import Foundation

#if canImport(ObjectiveC)
@objc(LeadDialogResponseParser)
#endif
final class LeadDialogResponseParser: NSObject {
    private static func key(_ peer: Api.Peer) -> String {
        switch peer {
        case .peerUser(let p): return "u\(p.userId)"
        case .peerChat(let p): return "g\(p.chatId)"
        case .peerChannel(let p): return "c\(p.channelId)"
        }
    }

    private static func record(_ title: String, kind: String, peer: Api.InputPeer, key: String) -> [String: Any] {
        let encoded = Buffer()
        peer.serialize(encoded, true)
        return ["title": title, "kind": kind, "peer": encoded.makeData() as NSData, "key": key]
    }

    #if canImport(ObjectiveC)
    @objc(parseDialogs:)
    #endif
    class func parseDialogs(_ bytes: NSData) -> NSDictionary? {
        guard let result = Api.parse(Buffer(data: bytes as Data)) as? Api.messages.Dialogs else { return nil }
        let dialogs: [Api.Dialog]
        let messages: [Api.Message]
        let chats: [Api.Chat]
        let users: [Api.User]
        let total: Int
        switch result {
        case .dialogs(let obj):
            dialogs = obj.dialogs; messages = obj.messages; chats = obj.chats
            users = obj.users; total = dialogs.count
        case .dialogsSlice(let obj):
            dialogs = obj.dialogs; messages = obj.messages; chats = obj.chats
            users = obj.users; total = Int(obj.count)
        case .dialogsNotModified:
            return nil
        }
        var peers = [String: [String: Any]]()
        for user in users {
            guard case .user(let obj) = user, let accessHash = obj.accessHash else { continue }
            let name = [obj.firstName ?? "", obj.lastName ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let display = name.isEmpty ? (obj.username ?? "مستخدم") : name
            let peer = Api.InputPeer.inputPeerUser(.init(userId: obj.id, accessHash: accessHash))
            peers["u\(obj.id)"] = record(display, kind: "خاص", peer: peer, key: "u\(obj.id)")
        }
        for chat in chats {
            switch chat {
            case .chat(let obj):
                let key = "g\(obj.id)"
                let peer = Api.InputPeer.inputPeerChat(.init(chatId: obj.id))
                peers[key] = record(obj.title, kind: "مجموعة", peer: peer, key: key)
            case .channel(let obj):
                guard let accessHash = obj.accessHash else { continue }
                let key = "c\(obj.id)"
                let peer = Api.InputPeer.inputPeerChannel(.init(channelId: obj.id, accessHash: accessHash))
                peers[key] = record(obj.title, kind: "مجموعة / قناة", peer: peer, key: key)
            default: break
            }
        }
        var dated = [String: [Int32: Int32]]()
        for message in messages {
            switch message {
            case .message(let obj):
                dated[key(obj.peerId), default: [:]][obj.id] = obj.date
            case .messageService(let obj):
                dated[key(obj.peerId), default: [:]][obj.id] = obj.date
            default: break
            }
        }
        var seen = Set<String>()
        var rows = [[String: Any]]()
        var nextOffset: [String: Any]? = nil
        for item in dialogs {
            guard case .dialog(let obj) = item else { continue }
            let k = key(obj.peer)
            if let peer = peers[k], !seen.contains(k) {
                seen.insert(k)
                rows.append(peer)
            }
            // Pagination must use the actual last dialog, even if it is not a
            // valid recipient (e.g. missing access hash or a hidden peer).
            let offsetPeer: Api.InputPeer?
            switch obj.peer {
            case .peerUser(let p):
                if let row = peers["u\(p.userId)"], let bytes = row["peer"] as? NSData {
                    nextOffset = ["peer": bytes, "date": dated[k]?[obj.topMessage] ?? 0,
                                  "id": obj.topMessage]
                }
                offsetPeer = nil
            case .peerChat(let p):
                offsetPeer = Api.InputPeer.inputPeerChat(.init(chatId: p.chatId))
            case .peerChannel(let p):
                if let row = peers["c\(p.channelId)"], let bytes = row["peer"] as? NSData {
                    nextOffset = ["peer": bytes, "date": dated[k]?[obj.topMessage] ?? 0,
                                  "id": obj.topMessage]
                }
                offsetPeer = nil
            }
            if let value = offsetPeer {
                let buffer = Buffer()
                value.serialize(buffer, true)
                nextOffset = ["peer": buffer.makeData() as NSData,
                              "date": dated[k]?[obj.topMessage] ?? 0, "id": obj.topMessage]
            }
        }
        return ["items": rows, "total": total, "hasMore": dialogs.count > 0 && total > dialogs.count,
                "next": nextOffset ?? [:]] as NSDictionary
    }
}
