import Foundation

// Only references actually published in accessible channel content. No member enumeration.
struct LeadUsernameReferences {
    static let handle = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_@./:+%\\-])@([A-Za-z][A-Za-z0-9_]{2,31})(?![A-Za-z0-9_])")
    static let links = try! NSRegularExpression(pattern: "(?i)(?<![A-Za-z0-9_.@/])(?:(?:https?://)?(?:t\\.me|telegram\\.me|telegram\\.dog)/[^\\s<>\\\"'،؛]+|tg://[^\\s<>\\\"'،؛]+)")
    static let namePattern = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_]{2,31}$")
    static let invitePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]+$")
    static func matches(_ value: String, _ regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
    static func target(_ original: String) -> (kind: String, value: String)? {
        let raw = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("@") || matches(raw, namePattern) {
            let name = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
            return matches(name, namePattern) ? ("username", name) : nil
        }
        let normalized = raw.contains("://") ? raw : "https://" + raw
        guard let url = URLComponents(string: normalized) else { return nil }
        if url.scheme?.lowercased() == "tg" {
            let host = url.host?.lowercased()
            let items = url.queryItems ?? []
            if host == "resolve", !items.contains(where: { ["post", "comment", "thread", "story"].contains($0.name.lowercased()) }),
               let name = items.first(where: { $0.name == "domain" })?.value, matches(name, namePattern) { return ("username", name) }
            if host == "join", let invite = items.first(where: { $0.name == "invite" })?.value, matches(invite, invitePattern) { return ("invite", invite) }
            return nil
        }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), ["t.me", "telegram.me", "telegram.dog"].contains(url.host?.lowercased() ?? "") else { return nil }
        guard !(url.queryItems ?? []).contains(where: { ["post", "comment", "thread", "story"].contains($0.name.lowercased()) }) else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.count == 2 && parts[0].lowercased() == "joinchat", matches(parts[1], invitePattern) { return ("invite", parts[1]) }
        if parts.count == 2 && parts[0].lowercased() == "s" { parts.removeFirst() }
        guard parts.count == 1 else { return nil } // exclude public/private message paths, stories, etc.
        let name = parts[0]
        if name.hasPrefix("+"), matches(String(name.dropFirst()), invitePattern) { return ("invite", String(name.dropFirst())) }
        guard matches(name, namePattern), !["share", "proxy", "socks", "joinchat", "addstickers", "addemoji", "setlanguage", "login", "boost", "giftcode", "invoice", "contact", "confirmphone", "folder", "addlist", "iv", "bg", "nft", "premium", "resolve"].contains(name.lowercased()) else { return nil }
        return ("username", name)
    }
    static func extract(_ text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var found = [String]()
        let linkMatches = links.matches(in: text, range: range)
        for match in linkMatches {
            let raw = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}»…"))
            if let t = target(raw) { found.append(t.kind == "invite" ? "https://t.me/+" + t.value : "@" + t.value) }
        }
        for match in handle.matches(in: text, range: range) where !linkMatches.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
            found.append("@" + ns.substring(with: match.range(at: 1)))
        }
        return found
    }
}

@objc(LeadUsernameScanner)
final class LeadUsernameScanner: NSObject {
    private static func bytes(_ buffer: Buffer) -> NSData { buffer.makeData() as NSData }
    private static func request(_ id: UInt32) -> Buffer { let b = Buffer(); b.appendInt32(Int32(bitPattern: id)); return b }
    @objc(resolveTarget:) static func resolveTarget(_ text: String) -> NSDictionary? {
        guard let target = LeadUsernameReferences.target(text) else { return nil }
        let b = request(target.kind == "invite" ? 0x3eadb1bb : 0x725afbbc)
        if target.kind != "invite" { b.appendInt32(0) }
        serializeString(target.value, buffer: b, boxed: false)
        return ["payload": bytes(b), "kind": target.kind, "targetValue": target.value] as NSDictionary
    }
    private static func channel(_ chat: Api.Chat) -> NSDictionary? {
        guard case let .channel(c) = chat, c.flags & (1 << 5) != 0, let hash = c.accessHash else { return nil }
        let peer = Buffer(); Api.InputPeer.inputPeerChannel(.init(channelId: c.id, accessHash: hash)).serialize(peer, true)
        let input = Buffer(); Api.InputChannel.inputChannel(.init(channelId: c.id, accessHash: hash)).serialize(input, true)
        return ["peer": bytes(peer), "channel": bytes(input), "title": c.title, "channelId": c.id, "username": c.username ?? ""] as NSDictionary
    }
    @objc(parseTarget:kind:) static func parseTarget(_ data: NSData, kind: String) -> NSDictionary? {
        let value = Api.parse(Buffer(data: data as Data))
        if kind == "invite" {
            guard let invite = value as? Api.ChatInvite else { return nil }
            switch invite {
            case .chatInviteAlready(let i): return channel(i.chat)
            case .chatInvitePeek(let i): return channel(i.chat)
            case .chatInvite: return ["error": "انضم للقناة أولاً بحسابك حتى تگدر تفحص الرسائل."]
            }
        }
        guard case let .resolvedPeer(r)? = value as? Api.contacts.ResolvedPeer, case let .peerChannel(p) = r.peer else { return nil }
        for chat in r.chats { if case let .channel(c) = chat, c.id == p.channelId { return channel(chat) } }
        return nil
    }
    @objc(fullRequest:) static func fullRequest(_ target: NSDictionary) -> NSData? {
        guard let data = target["channel"] as? NSData, let peer = Api.parse(Buffer(data: data as Data)) as? Api.InputChannel else { return nil }
        let b = request(0x08736a09); peer.serialize(b, true); return bytes(b)
    }
    @objc(parseFull:) static func parseFull(_ data: NSData) -> NSArray? {
        guard case let .chatFull(r)? = Api.parse(Buffer(data: data as Data)) as? Api.messages.ChatFull, case let .channelFull(c) = r.fullChat else { return nil }
        return LeadUsernameReferences.extract(c.about) as NSArray
    }
    @objc(pageRequest:offset:pinned:limit:) static func pageRequest(_ target: NSDictionary, offset: Int32, pinned: Bool, limit: Int32) -> NSData? {
        guard let data = target["peer"] as? NSData, let peer = Api.parse(Buffer(data: data as Data)) as? Api.InputPeer else { return nil }
        let b = request(pinned ? 0x29ee847a : 0x4423e6c5)
        if pinned { b.appendInt32(0) }
        peer.serialize(b, true)
        if pinned {
            serializeString("", buffer: b, boxed: false); b.appendInt32(Int32(bitPattern: 0x1bb00451)); b.appendInt32(0); b.appendInt32(0); b.appendInt32(offset)
        } else { b.appendInt32(offset); b.appendInt32(0) }
        b.appendInt32(0); b.appendInt32(limit); b.appendInt32(0); b.appendInt32(0); b.appendInt64(0)
        return bytes(b)
    }
    @objc(parsePage:) static func parsePage(_ data: NSData) -> NSDictionary? {
        // Parse only the message vector, not unrelated users/chats that may have newer schema.
        guard let page = LeadMessageDiscoveryBridge.tolerantMessages(data) else { return nil }
        var refs = [[String: Any]](); var offset = Int32.max; var count = 0
        for message in page.messages {
            switch message {
            case .message(let m):
                offset = min(offset, m.id); count += 1
                var messageRefs = LeadUsernameReferences.extract(m.message)
                for entity in m.entities ?? [] {
                    if case let .messageEntityTextUrl(e) = entity { messageRefs += LeadUsernameReferences.extract(e.url) }
                }
                if case let .replyInlineMarkup(markup)? = m.replyMarkup {
                    for case let .keyboardInlineButtonRow(row) in markup.rows {
                        for case let .keyboardInlineButton(button) in row.buttons {
                            messageRefs += LeadUsernameReferences.extract(button.text)
                            switch button.type {
                            case .inlineButtonTypeUrl(let u): messageRefs += LeadUsernameReferences.extract(u.url)
                            case .inlineButtonTypeUrlAuth(let u): messageRefs += LeadUsernameReferences.extract(u.url)
                            default: break
                            }
                        }
                    }
                }
                for ref in Set(messageRefs) { refs.append(["value": ref, "messageId": m.id]) }
            case .messageEmpty(let m): offset = min(offset, m.id)
            case .messageService(let m): offset = min(offset, m.id)
            }
        }
        return ["refs": refs, "offset": offset == Int32.max ? 0 : offset, "count": count, "returned": page.messages.count, "partial": page.failed] as NSDictionary
    }
}
