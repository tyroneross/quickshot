import Foundation

public enum ClipKind: String, Sendable, CaseIterable {
    case text
    case image
    /// One or more files, kept as paths. The files themselves are not copied.
    case files
}

/// What one copy produced, before it is stored.
public struct ClipCandidate: Sendable, Equatable {
    public var kind: ClipKind
    /// The text, or one file path per line for `files`. Empty for an image.
    public var text: String
    /// PNG bytes for an image.
    public var imageData: Data?
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Bundle identifier of the app in front when the copy happened.
    public var sourceApp: String?

    public init(kind: ClipKind, text: String = "", imageData: Data? = nil,
                pixelWidth: Int = 0, pixelHeight: Int = 0, sourceApp: String? = nil) {
        self.kind = kind
        self.text = text
        self.imageData = imageData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceApp = sourceApp
    }

    public static func text(_ string: String, sourceApp: String? = nil) -> ClipCandidate {
        ClipCandidate(kind: .text, text: string, sourceApp: sourceApp)
    }

    public static func files(_ urls: [URL], sourceApp: String? = nil) -> ClipCandidate {
        ClipCandidate(kind: .files, text: urls.map(\.path).joined(separator: "\n"), sourceApp: sourceApp)
    }

    var byteCount: Int { imageData?.count ?? text.utf8.count }
}

/// One stored item of clipboard history.
public struct ClipItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let kind: ClipKind
    public let text: String
    /// File name of the stored image, inside the store's images folder.
    public let imageFile: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int
    public let sourceApp: String?
    public let created: Date
    public let lastCopied: Date

    public var filePaths: [String] {
        kind == .files ? text.split(separator: "\n").map(String.init) : []
    }

    /// One line that names the item in a list.
    public var title: String {
        switch kind {
        case .text:
            let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? "Blank text"
        case .image:
            return "Image \(pixelWidth) × \(pixelHeight)"
        case .files:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            switch names.count {
            case 0: return "No files"
            case 1: return names[0]
            default: return "\(names[0]) and \(names.count - 1) more"
            }
        }
    }
}

public struct ClipCollection: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var name: String
}
