import Foundation
import Observation

enum PhotoSelectionStatus: Equatable {
    case selected
    case excluded
    case uploaded
}

@MainActor
@Observable
final class PhotoSelectionStore {
    private enum Key {
        static let excluded = "photo-selection.excluded"
        static let uploaded = "photo-selection.uploaded"
    }

    private(set) var selectedIDs: Set<String> = []
    private var excludedIDs: Set<String>
    private var uploadedIDs: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        excludedIDs = Set(defaults.stringArray(forKey: Key.excluded) ?? [])
        uploadedIDs = Set(defaults.stringArray(forKey: Key.uploaded) ?? [])
    }

    func updatePhotos(_ assetIDs: [String]) {
        selectedIDs = Set(assetIDs).subtracting(excludedIDs).subtracting(uploadedIDs)
    }

    func toggle(_ assetID: String) {
        guard !uploadedIDs.contains(assetID) else { return }
        if selectedIDs.contains(assetID) {
            selectedIDs.remove(assetID)
            excludedIDs.insert(assetID)
        } else {
            selectedIDs.insert(assetID)
            excludedIDs.remove(assetID)
        }
        persist()
    }

    func markUploaded(_ assetIDs: [String]) {
        uploadedIDs.formUnion(assetIDs)
        selectedIDs.subtract(assetIDs)
        excludedIDs.subtract(assetIDs)
        persist()
    }

    func status(of assetID: String) -> PhotoSelectionStatus {
        if uploadedIDs.contains(assetID) { return .uploaded }
        if selectedIDs.contains(assetID) { return .selected }
        return .excluded
    }

    private func persist() {
        defaults.set(Array(excludedIDs), forKey: Key.excluded)
        defaults.set(Array(uploadedIDs), forKey: Key.uploaded)
    }
}
