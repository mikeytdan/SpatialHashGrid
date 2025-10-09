import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MapFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static let contentType: UTType = .json

    var document: MapDocument

    init(document: MapDocument) {
        self.document = document
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw MapDocumentError.missingPayload
        }
        self.document = try MapDocument.decode(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try document.encodedData(prettyPrinted: true)
        return .init(regularFileWithContents: data)
    }

    static func placeholder() -> MapFileDocument {
        MapFileDocument(
            document: MapDocument(
                blueprint: LevelBlueprint(rows: 1, columns: 1, tileSize: 32),
                metadata: MapDocumentMetadata(name: "Untitled")
            )
        )
    }
}
