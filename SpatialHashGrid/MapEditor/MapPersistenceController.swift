import Foundation

final class MapPersistenceController {
    static let shared = MapPersistenceController()

    private let fileManager: FileManager
    private let autosaveQueue = DispatchQueue(label: "MapPersistenceController.autosave", qos: .utility)
    private let autosaveFilename = "Autosave.map.json"
    private let folderName = "SpatialHashGridMaps"
    private let baseDirectory: URL
    private let autosaveURL: URL

    init(fileManager: FileManager = .default, baseDirectoryOverride: URL? = nil) {
        self.fileManager = fileManager

        if let override = baseDirectoryOverride {
            self.baseDirectory = override
        } else {
            let suggested: URL
            #if os(macOS)
            suggested = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            #else
            suggested = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            #endif
            self.baseDirectory = suggested
        }

        let folder = baseDirectory.appendingPathComponent(folderName, isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                // fallback to temporary directory if the primary location fails
                let fallback = fileManager.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
                if !fileManager.fileExists(atPath: fallback.path) {
                    try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
                }
                self.autosaveURL = fallback.appendingPathComponent(autosaveFilename)
                return
            }
        }
        self.autosaveURL = folder.appendingPathComponent(autosaveFilename)
    }

    func loadAutosave() -> MapDocument? {
        guard fileManager.fileExists(atPath: autosaveURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: autosaveURL)
            guard !data.isEmpty else { return nil }
            return try MapDocument.decode(from: data)
        } catch {
            return nil
        }
    }

    func saveAutosave(document: MapDocument) {
        autosaveQueue.async { [autosaveURL] in
            do {
                let data = try document.encodedData(prettyPrinted: false)
                try data.write(to: autosaveURL, options: .atomic)
            } catch {
                // Intentionally swallow to avoid surfacing autosave failures to UI.
            }
        }
    }
}
