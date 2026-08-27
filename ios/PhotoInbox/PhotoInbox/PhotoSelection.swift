import Foundation

struct PhotoSelection: Equatable {
    private(set) var selectedIDs: Set<String>

    init(assetIDs: [String]) {
        selectedIDs = Set(assetIDs)
    }

    mutating func toggle(_ assetID: String) {
        if selectedIDs.contains(assetID) {
            selectedIDs.remove(assetID)
        } else {
            selectedIDs.insert(assetID)
        }
    }
}
