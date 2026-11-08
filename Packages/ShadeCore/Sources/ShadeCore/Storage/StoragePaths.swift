import Foundation

/// Where Shade keeps its data on the device.
///
/// | Path                                   | Contents                         | Visible in Files app |
/// |----------------------------------------|----------------------------------|----------------------|
/// | Documents/Recipes/*.shade              | the recipe library               | yes                  |
/// | Documents/*.shade (inbox)              | files dropped in via Finder      | yes, imported on launch |
/// | Application Support/Shade/state.json   | current look + unsaved edits     | no                   |
/// | Keychain (service com.shadeapp.shade)  | Claude API key                   | no                   |
/// | UserDefaults                           | model / effort settings          | no                   |
public struct StoragePaths: Sendable {
    public let documents: URL
    public let applicationSupport: URL

    public init(documents: URL, applicationSupport: URL) {
        self.documents = documents
        self.applicationSupport = applicationSupport
    }

    public static func standard(fileManager: FileManager = .default) -> StoragePaths {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StoragePaths(documents: docs, applicationSupport: support.appendingPathComponent("Shade", isDirectory: true))
    }

    public var recipesDirectory: URL { documents.appendingPathComponent("Recipes", isDirectory: true) }
    public var inboxDirectory: URL { documents }
    public var sessionFile: URL { applicationSupport.appendingPathComponent("state.json") }
}
