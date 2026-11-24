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


    // Unlike getCommonChats, getDialogs includes groups the account still has
    // access to even if the selected sender left them years ago.
    @objc(dialogsRequestWithOffsetDate:offsetId:offsetPeer:folderId:)
    static func dialogsRequest(offsetDate: Int32, offsetId: Int32,
                               offsetPeer: NSData?, folderId: Int32) -> NSData {
        let buffer = Buffer()
        buffer.appendInt32(Int32(bitPattern: 0xa0f4cb4f)) // messages.getDialogs
        buffer.appendInt32(folderId == 1 ? (1 << 1) : 0)
        if folderId == 1 { buffer.appendInt32(1) } // archived folder
        buffer.appendInt32(offsetDate)
        buffer.appendInt32(offsetId)
        if let peer = offsetPeer, let parsed = decodePeer(peer) {
            parsed.serialize(buffer, true)
        } else {
            buffer.appendInt32(2134579434) // inputPeerEmpty
        }
        buffer.appendInt32(100)
        buffer.appendInt64(0)
        return buffer.makeData() as NSData
    }

    private static func key(for peer: Api.Peer) -> String {
        switch peer {
        case .peerUser(let p): return "u\(p.userId)"
        case .peerChat(let p): return "g\(p.chatId)"
        case .peerChannel(let p): return "c\(p.channelId)"
        }
    }

    private static func groupSources(from chats: [Api.Chat],
                                     scope: String,
                                     publicOnly: Bool) -> [[String: Any]] {
        var items = [[String: Any]]()
        for chat in chats {
            switch chat {
            case .chat(let value):
                if publicOnly { continue } // legacy chats have no public username
                items.append([
                    "id": NSNumber(value: value.id),
                    "key": "g\(value.id)", "kind": "g",
                    "title": value.title, "username": "",
                    "scope": scope,
                    "peer": peerData(.inputPeerChat(.init(chatId: value.id)))
                ])
            case .channel(let value):
                if value.flags & (1 << 5) != 0 { continue } // broadcast channel
                guard let hash = value.accessHash else { continue }
                let username = value.username ?? ""
                if publicOnly && username.isEmpty { continue }
                items.append([
                    "id": NSNumber(value: value.id),
                    "key": "c\(value.id)", "kind": "c",
                    "title": value.title, "username": username,
                    "scope": scope,
                    "peer": peerData(.inputPeerChannel(
                        .init(channelId: value.id, accessHash: hash)))
                ])
            case .community(let value):
                if publicOnly { continue }
                guard let hash = value.accessHash else { continue }
                items.append([
                    "id": NSNumber(value: value.id),
                    "key": "c\(value.id)", "kind": "c",
                    "title": value.title, "username": "",
                    "scope": scope,
                    "peer": peerData(.inputPeerChannel(
                        .init(channelId: value.id, accessHash: hash)))
                ])
            default: continue
            }
        }
        return items
    }

    @objc(parseDiscoveryDialogs:)
    static func parseDiscoveryDialogs(_ bytes: NSData) -> NSDictionary? {
        guard let response = payload(bytes) as? Api.messages.Dialogs else { return nil }
        let dialogs: [Api.Dialog]
        let chats: [Api.Chat]
        let users: [Api.User]
        let messages: [Api.Message]
        switch response {
        case .dialogs(let item):
            dialogs = item.dialogs; chats = item.chats
            users = item.users; messages = item.messages
        case .dialogsSlice(let item):
            dialogs = item.dialogs; chats = item.chats
            users = item.users; messages = item.messages
        case .dialogsNotModified:
            return nil
        }

        let groups = groupSources(from: chats, scope: "كروب بحسابك", publicOnly: false)
        var inputPeers = [String: Api.InputPeer]()
        for record in groups {
            if let key = record["key"] as? String,
               let bytes = record["peer"] as? NSData,
               let peer = decodePeer(bytes) { inputPeers[key] = peer }
        }
        for user in users {
            if case .user(let item) = user, let hash = item.accessHash {
                inputPeers["u\(item.id)"] = .inputPeerUser(
                    .init(userId: item.id, accessHash: hash))
            }
        }

        var messageDates = [String: [Int32: Int32]]()
        for message in messages {
            switch message {
            case .message(let item):
                messageDates[key(for: item.peerId), default: [:]][item.id] = item.date
            case .messageService(let item):
                messageDates[key(for: item.peerId), default: [:]][item.id] = item.date
            default: break
            }
        }

        var nextPeer: NSData?
        var nextId: Int32 = 0
        var nextDate: Int32 = 0
        for dialog in dialogs {
            guard case .dialog(let item) = dialog else { continue }
            let k = key(for: item.peer)
            guard let input = inputPeers[k] else { continue }
            nextPeer = peerData(input)
            nextId = item.topMessage
            nextDate = messageDates[k]?[item.topMessage] ?? 0
        }
        return [
            "items": groups,
            "returned": NSNumber(value: dialogs.count),
            "hasMore": NSNumber(value: dialogs.count >= 100 && nextPeer != nil),
            "next": nextPeer.map {
                ["peer": $0, "id": NSNumber(value: nextId),
                 "date": NSNumber(value: nextDate)] as [String: Any]
            } ?? [:]
        ] as NSDictionary
    }

    // This first-party API search covers *normal* groups/private dialogs when
    // the input peer is empty. It does not index all Telegram supergroups.
    @objc(legacySenderGroupsRequest:)
    static func legacySenderGroupsRequest(_ sender: NSData) -> NSData? {
        let buffer = Buffer()
        buffer.appendInt32(2134579434) // inputPeerEmpty
        return searchRequest(peer: buffer.makeData() as NSData,
                             sender: sender, category: 7, offsetId: 0)
    }

    // Broad text query, NOT a global sender search. Results only nominate
    // public groups for subsequent server-side from_id verification.
    @objc(publicGroupCandidatesRequestForUsername:)
    static func publicGroupCandidatesRequest(username: String) -> NSData {
        let buffer = Buffer()
        buffer.appendInt32(Int32(bitPattern: 0x4bc6589a)) // messages.searchGlobal
        buffer.appendInt32(1 << 2) // groups_only
        serializeString(username, buffer: buffer, boxed: false)
        buffer.appendInt32(Int32(bitPattern: 0x57e2f66c)) // no media filter
        buffer.appendInt32(0) // min_date
        buffer.appendInt32(0) // max_date
        buffer.appendInt32(0) // offset_rate
        buffer.appendInt32(2134579434) // offset_peer: empty
        buffer.appendInt32(0) // offset_id
        buffer.appendInt32(100) // limit
        return buffer.makeData() as NSData
    }

    @objc(parseDiscoveredGroups:scope:)
    static func parseDiscoveredGroups(_ bytes: NSData,
                                      scope: String) -> NSDictionary? {
        guard let response = payload(bytes) as? Api.messages.Messages else { return nil }
        let messages: [Api.Message]
        let chats: [Api.Chat]
        switch response {
        case .messages(let value):
            messages = value.messages; chats = value.chats
        case .messagesSlice(let value):
            messages = value.messages; chats = value.chats
        case .channelMessages(let value):
            messages = value.messages; chats = value.chats
        case .messagesNotModified:
            return nil
        }
        // Only consider chats actually represented in the result messages.
        // Never claim that a mere username mention proves the target sent there.
        var represented = Set<String>()
        for message in messages {
            switch message {
            case .message(let item): _ = represented.insert(key(for: item.peerId))
            case .messageService(let item): _ = represented.insert(key(for: item.peerId))
            default: break
            }
        }
        let candidates = groupSources(
            from: chats, scope: scope, publicOnly: scope == "مرشّح من البحث العام")
            .filter { represented.contains($0["key"] as? String ?? "") }
        return [
            "items": candidates,
            "returned": NSNumber(value: messages.count)
        ] as NSDictionary
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
        buffer.appendInt32(Int32(bitPattern: 0x57e2f66c)) // empty filter; classify locally
        buffer.appendInt32(0) // min_date
        buffer.appendInt32(0) // max_date
        buffer.appendInt32(offsetId)
        buffer.appendInt32(0) // add_offset
        buffer.appendInt32(100) // sender messages per page
        buffer.appendInt32(0) // max_id
        buffer.appendInt32(0) // min_id
        buffer.appendInt64(0) // hash: do not use cache-only responses
        return buffer.makeData() as NSData
    }

    // The generated vector parser throws away the WHOLE page when a single
    // message uses a constructor it does not know (new media/flags). A page of
    // search results is mostly media, so that made every category look empty.
    // Read the header ourselves and keep every message that does parse.
    static func tolerantMessages(_ bytes: NSData) -> (messages: [Api.Message], failed: Bool)? {
        let reader = BufferReader(Buffer(data: bytes as Data))
        guard let signature = reader.readInt32() else { return nil }
        switch signature {
        case 494135274:            // messages.messages
            break
        case 1595959062:           // messages.messagesSlice
            guard let flags = reader.readInt32(), reader.readInt32() != nil else { return nil }
            if flags & (1 << 0) != 0 { guard reader.readInt32() != nil else { return nil } }
            if flags & (1 << 2) != 0 { guard reader.readInt32() != nil else { return nil } }
            if flags & (1 << 3) != 0 {
                guard let flood = reader.readInt32(),
                      Api.parse(reader, signature: flood) != nil else { return nil }
            }
        case -948520370:           // messages.channelMessages
            guard let flags = reader.readInt32(),
                  reader.readInt32() != nil, reader.readInt32() != nil else { return nil }
            if flags & (1 << 2) != 0 { guard reader.readInt32() != nil else { return nil } }
        default:
            return nil
        }
        guard reader.readInt32() == 481674261,               // vector constructor
              let count = reader.readInt32(), count >= 0, count <= 1000 else { return nil }
        var result = [Api.Message]()
        var failed = false
        var index: Int32 = 0
        while index < count {
            guard let elementSignature = reader.readInt32(),
                  let message = Api.parse(reader, signature: elementSignature) as? Api.Message else {
                failed = true
                break
            }
            result.append(message)
            index += 1
        }
        return (result, failed)
    }

    @objc(parseSearchResult:senderId:source:category:)
    static func parseSearchResult(_ bytes: NSData, senderId: Int64,
                                  source: NSDictionary, category: Int) -> NSDictionary? {
        guard let parsed = tolerantMessages(bytes) else { return nil }
        let messages = parsed.messages
        let partial = parsed.failed
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
            // Combining from_id with a media filter is rejected by some peers.
            // Search by sender only, then classify the actual message content.
            var mediaCategory = -1
            if let media = value.media {
                switch media {
                case .messageMediaPhoto: mediaCategory = 0
                case let .messageMediaDocument(item):
                    mediaCategory = 4
                    if case let .document(document)? = item.document {
                        for attribute in document.attributes {
                            switch attribute {
                            case let .documentAttributeAudio(audio):
                                mediaCategory = audio.flags & (1 << 10) != 0 ? 2 : 3
                            case let .documentAttributeVideo(video):
                                mediaCategory = video.flags & 1 != 0 ? 5 : 1
                            default: break
                            }
                        }
                    }
                default: break
                }
            }
            let hasLink = (value.entities ?? []).contains { entity in
                switch entity {
                case .messageEntityUrl, .messageEntityTextUrl: return true
                default: return false
                }
            }
            if category != 7 && !(category == 6 ? hasLink : mediaCategory == category) { continue }
            let labels = ["صورة", "فيديو", "فويس", "موسيقى", "ملف", "فيديو دائري"]
            let type = category == 6 ? "رابط" : (mediaCategory >= 0 ? labels[mediaCategory] : "رسالة")
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
            "partial": NSNumber(value: partial),
            "nextOffset": NSNumber(value: lowestId == Int32.max ? 0 : lowestId),
            "hasMore": (messages.count >= 100 || partial) && lowestId > 1
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
