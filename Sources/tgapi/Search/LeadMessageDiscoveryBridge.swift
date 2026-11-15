// Message Explorer protocol adapter for Lead.
// Uses Telegram's own MTProto session (no external service or account login).
// All returned searches are restricted to the chats visible to this account.
import Foundation

@objc(LeadMessageDiscoveryBridge)
final class LeadMessageDiscoveryBridge: NSObject {
    private static func payload(_ bytes: NSData) -> Any? {
        return Api.parse(Buffer(data: bytes as Data))
    }

    private static func peerData(_ peer: Api.InputPeer) -> NSData {
        let buffer = Buffer()
        peer.serialize(buffer, true)
        return buffer.makeData() as NSData
    }

    private static func decodePeer(_ bytes: NSData) -> Api.InputPeer? {
        return payload(bytes) as? Api.InputPeer
    }

    // contacts.resolveUsername#725afbbc flags:# username:string referer:flags.0?string
    @objc(resolveRequestForUsername:)
    static func resolveRequest(username: String) -> NSData {
        let buffer = Buffer()
        buffer.appendInt32(Int32(bitPattern: 0x725afbbc))
        buffer.appendInt32(0)
        serializeString(username.trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\r\t")),
                        buffer: buffer, boxed: false)
        return buffer.makeData() as NSData
    }

    @objc(parseResolvedUser:)
    static func parseResolvedUser(_ bytes: NSData) -> NSDictionary? {
        guard case let .resolvedPeer(resolved)? = payload(bytes) as? Api.contacts.ResolvedPeer,
              case let .peerUser(peer) = resolved.peer else { return nil }
        for user in resolved.users {
            guard case let .user(item) = user,
                  item.id == peer.userId,
                  let accessHash = item.accessHash else { continue }
            let name = [item.firstName, item.lastName].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: " ")
            let target = Api.InputPeer.inputPeerUser(
                .init(userId: item.id, accessHash: accessHash))
            return [
                "userId": NSNumber(value: item.id),
                "accessHash": NSNumber(value: accessHash),
                "username": item.username ?? "",
                "title": name.isEmpty ? (item.username ?? "Telegram") : name,
                "peer": peerData(target)
            ] as NSDictionary
        }
        return nil
    }

    // messages.getCommonChats#e40ca104 user_id:InputUser max_id:long limit:int
    @objc(commonChatsRequestForUserId:accessHash:maxId:)
    static func commonChatsRequest(userId: Int64, accessHash: Int64, maxId: Int64) -> NSData {
        let buffer = Buffer()
        buffer.appendInt32(Int32(bitPattern: 0xe40ca104))
        buffer.appendInt32(Int32(bitPattern: 0xf21158c6)) // inputUser
        buffer.appendInt64(userId)
        buffer.appendInt64(accessHash)
        buffer.appendInt64(maxId)
        buffer.appendInt32(100)
        return buffer.makeData() as NSData
    }

    @objc(parseCommonChats:)
    static func parseCommonChats(_ bytes: NSData) -> NSDictionary? {
        guard let response = payload(bytes) as? Api.messages.Chats else { return nil }
        let chats: [Api.Chat]
        let total: Int
        switch response {
        case .chats(let value):
            chats = value.chats
            total = chats.count
        case .chatsSlice(let value):
            chats = value.chats
            total = Int(value.count)
        }
        var result = [[String: Any]]()
        var lastId: Int64 = 0
        // The last returned chat ID (including unavailable chats) is the pagination cursor.
        for chat in chats {
            switch chat {
            case .chat(let value):
                lastId = value.id
                result.append([
                    "id": NSNumber(value: value.id), "key": "g\(value.id)",
                    "kind": "g", "title": value.title, "username": "",
                    "peer": peerData(.inputPeerChat(.init(chatId: value.id)))
                ])
            case .channel(let value):
                lastId = value.id
                // Broadcast channels are not shared group conversations.
                if value.flags & (1 << 5) != 0 { continue }
                guard let hash = value.accessHash else { continue }
                result.append([
                    "id": NSNumber(value: value.id), "key": "c\(value.id)",
                    "kind": "c", "title": value.title,
                    "username": value.username ?? "",
                    "peer": peerData(.inputPeerChannel(.init(channelId: value.id, accessHash: hash)))
                ])
            case .channelForbidden(let value):
                lastId = value.id
            case .chatEmpty(let value):
                lastId = value.id
            case .chatForbidden(let value):
                lastId = value.id
            case .community(let value):
                lastId = value.id
                guard let hash = value.accessHash else { continue }
                result.append([
                    "id": NSNumber(value: value.id), "key": "c\(value.id)",
                    "kind": "c", "title": value.title, "username": "",
                    "peer": peerData(.inputPeerChannel(.init(channelId: value.id, accessHash: hash)))
                ])
            case .communityForbidden(let value):
                lastId = value.id
            }
        }
        return [
            "items": result,
            "total": total,
            "nextMaxId": NSNumber(value: lastId),
            "hasMore": chats.count == 100 || total > chats.count
        ] as NSDictionary
    }

    // The filter constructors are part of Telegram layer 233, but this
    // project's compact generated Api.functions subset omits search methods.
    private static func filterForCategory(_ category: Int) -> Int32 {
        switch category {
        case 0: return Int32(bitPattern: 0x9609a51c) // photos
        case 1: return Int32(bitPattern: 0x9fc00e65) // videos
        case 2: return Int32(bitPattern: 0x50f5c392) // voice notes
        case 3: return Int32(bitPattern: 0x3751b49e) // music
        case 4: return Int32(bitPattern: 0x9eddf188) // files
        case 5: return Int32(bitPattern: 0xb549da53) // round videos
        case 6: return Int32(bitPattern: 0x7ef0dd87) // links
        default: return Int32(bitPattern: 0x9609a51c) // photos
        }
    }

    // messages.search#29ee847a flags:# peer:InputPeer q:string
    // from_id:flags.0?InputPeer ... filter:MessagesFilter min_date:int
    // max_date:int offset_id:int add_offset:int limit:int max_id:int min_id:int hash:long
    @objc(searchRequestForPeer:sender:category:offsetId:)
    static func searchRequest(peer: NSData, sender: NSData,
                              category: Int, offsetId: Int32) -> NSData? {
        guard let inputPeer = decodePeer(peer),
              let fromPeer = decodePeer(sender) else { return nil }
        let buffer = Buffer()
        buffer.appendInt32(Int32(bitPattern: 0x29ee847a))
        buffer.appendInt32(1) // flags.0 = from_id
        inputPeer.serialize(buffer, true)
        serializeString("", buffer: buffer, boxed: false)
        fromPeer.serialize(buffer, true)
        buffer.appendInt32(filterForCategory(category))
        buffer.appendInt32(0) // min_date
        buffer.appendInt32(0) // max_date
        buffer.appendInt32(offsetId)
        buffer.appendInt32(0) // add_offset
        buffer.appendInt32(30) // results per chat/page
        buffer.appendInt32(0) // max_id
        buffer.appendInt32(0) // min_id
        buffer.appendInt64(0) // hash: do not use cache-only responses
        return buffer.makeData() as NSData
    }

    @objc(parseSearchResult:senderId:source:category:)
    static func parseSearchResult(_ bytes: NSData, senderId: Int64,
                                  source: NSDictionary, category: Int) -> NSDictionary? {
        guard let response = payload(bytes) as? Api.messages.Messages else { return nil }
        let messages: [Api.Message]
        switch response {
        case .messages(let value): messages = value.messages
        case .messagesSlice(let value): messages = value.messages
        case .channelMessages(let value): messages = value.messages
        case .messagesNotModified: return nil
        }
        let key = source["key"] as? String ?? ""
        let title = source["title"] as? String ?? "Telegram"
        let sourcePeer = source["peer"] as? NSData ?? NSData()
        let kind = source["kind"] as? String ?? ""
        let username = source["username"] as? String ?? ""
        var rows = [[String: Any]]()
        var lowestId: Int32 = Int32.max
        for message in messages {
            guard case let .message(value) = message else { continue }
            lowestId = min(lowestId, value.id)
            // Strict sender verification; forwarded messages keep their forward
            // header, but their actual sender is not rewritten.
            if let author = value.fromId {
                guard case let .peerUser(peer) = author, peer.userId == senderId else { continue }
            } else if kind != "u" || value.flags & (1 << 1) != 0 {
                continue
            }
            let type: String
            if category == 0 { type = "صورة" }
            else if category == 1 { type = "فيديو" }
            else if category == 2 { type = "فويس" }
            else if category == 3 { type = "موسيقى" }
            else if category == 4 { type = "ملف" }
            else if category == 5 { type = "فيديو دائري" }
            else { type = "رابط" }
            rows.append([
                "id": NSNumber(value: value.id),
                "date": NSNumber(value: value.date),
                "title": title, "text": value.message,
                "type": type, "key": key,
                "sourcePeer": sourcePeer,
                "kind": kind, "username": username,
                "sourceId": source["id"] ?? NSNumber(value: senderId),
                "protected": NSNumber(value: value.flags & (1 << 26) != 0)
            ])
        }
        // Telegram's filter/search is already server-side. An unfilled final
        // page has no more results; later pages are fetched only on demand.
        return [
            "items": rows,
            "nextOffset": NSNumber(value: lowestId == Int32.max ? 0 : lowestId),
            "hasMore": messages.count >= 30 && lowestId > 1
        ] as NSDictionary
    }

    // messages.forwardMessages#13704a7c
    // flags:# from_peer:InputPeer id:Vector<int> random_id:Vector<long>
    // to_peer:InputPeer, followed by optional fields according to flags.
    // No drop_author: the recipient must see ordinary forwarded messages.
    @objc(forwardRequestForPeer:messageIds:)
    static func forwardRequest(peer: NSData, messageIds: [NSNumber]) -> NSData? {
        guard let from = decodePeer(peer),
              !messageIds.isEmpty, messageIds.count <= 100 else { return nil }
        let buffer = Buffer()
        buffer.appendInt32(Int32(bitPattern: 0x13704a7c))
        buffer.appendInt32(0) // no silent/drop_author/other optional flags
        from.serialize(buffer, true)
        buffer.appendInt32(481674261)
        buffer.appendInt32(Int32(messageIds.count))
        for id in messageIds { buffer.appendInt32(id.int32Value) }
        buffer.appendInt32(481674261)
        buffer.appendInt32(Int32(messageIds.count))
        for _ in messageIds { buffer.appendInt64(Int64.random(in: Int64.min...Int64.max)) }
        buffer.appendInt32(2107670217) // inputPeerSelf: Saved Messages
        return buffer.makeData() as NSData
    }
}
