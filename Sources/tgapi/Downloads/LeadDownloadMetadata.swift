import Foundation

// Extract real document IDs, sizes and filenames from Telegram API responses.
// Never manufacture a total size: a progress percentage is displayed only
// after a document is matched to its upload.getFile request.
@objc(LeadDownloadMetadata)
final class LeadDownloadMetadata: NSObject {
    private static let parseQueue = DispatchQueue(label: "lead.download.metadata", qos: .utility)

    @objc(observeResponse:)
    static func observeResponse(_ data: NSData) {
        guard UserDefaults.standard.bool(forKey: "LeadShowDownloadProgress"),
              data.length >= 8, data.length <= 512 * 1024 else { return }
        let bytes = data as Data
        parseQueue.async {
            let reader = BufferReader(Buffer(data: bytes))
            guard let signature = reader.readInt32(),
                  let object = Api.parse(reader, signature: signature) else { return }
            var count = 0
            visit(object, depth: 0, remaining: &count)
        }
    }

    private static func visit(_ object: Any, depth: Int, remaining: inout Int) {
        guard depth < 18, remaining < 6000 else { return }
        remaining += 1
        if let document = object as? Api.Document {
            if case let .document(doc) = document {
                let name: String = doc.attributes.compactMap { attr in
                    if case let .documentAttributeFilename(value) = attr { return value.fileName }
                    return nil
                }.first ?? "Telegram file"
                guard doc.size > 0 else { return }
                NotificationCenter.default.post(
                    name: Notification.Name("LeadDownloadDocumentMetadata"), object: nil,
                    userInfo: ["id": NSNumber(value: doc.id),
                               "size": NSNumber(value: doc.size),
                               "name": name, "dc": NSNumber(value: doc.dcId)])
            }
            return
        }
        // Generated API objects are enums with reference-type associated
        // storage. Traverse through vectors, classes, and optionals only.
        if object is String || object is NSData || object is Data ||
           object is Buffer || object is NSNumber ||
           object is Int || object is Int32 || object is Int64 ||
           object is Double || object is Float || object is Bool { return }
        let mirror = Mirror(reflecting: object)
        for child in mirror.children {
            if remaining >= 6000 { break }
            visit(child.value, depth: depth + 1, remaining: &remaining)
        }
    }
}
