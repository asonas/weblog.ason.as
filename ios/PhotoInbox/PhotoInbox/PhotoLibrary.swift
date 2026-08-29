@preconcurrency import Photos
import SwiftUI
import os

struct LibraryPhoto: Identifiable, Sendable {
    let id: String
    let capturedAt: Date
    let capturedAtSource: String
    fileprivate let asset: PHAsset
}

@MainActor
@Observable
final class PhotoLibrary {
    private let logger = Logger(subsystem: "com.asonas.weblog.PhotoInbox", category: "PhotoLibrary")
    private(set) var photos: [LibraryPhoto] = []
    private(set) var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private let manager = PHCachingImageManager()

    var canRead: Bool { authorizationStatus == .authorized || authorizationStatus == .limited }

    func requestAccess() async {
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        logger.notice("Photo authorization changed to \(self.authorizationStatus.rawValue)")
        if canRead { loadRecentPhotos() }
    }

    func refreshAuthorizationAndPhotos() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if canRead { loadRecentPhotos() }
    }

    func loadRecentPhotos(now: Date = .now, calendar: Calendar = .current) {
        guard canRead else { return }
        let interval = Self.recentPhotoInterval(now: now, calendar: calendar)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            interval.start as NSDate, interval.end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        logger.notice(
            "Fetching recent photos from \(interval.start, privacy: .public) to \(interval.end, privacy: .public): \(result.count) assets"
        )
        var loaded: [LibraryPhoto] = []
        result.enumerateObjects { asset, _, _ in
            let capturedAt = asset.creationDate
            loaded.append(.init(
                id: asset.localIdentifier,
                capturedAt: capturedAt ?? now,
                capturedAtSource: capturedAt == nil ? "uploaded" : "photos",
                asset: asset
            ))
        }
        photos = loaded
    }

    static func recentPhotoInterval(now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        return DateInterval(start: start, end: end)
    }

    func thumbnail(for photo: LibraryPhoto, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            manager.requestImage(
                for: photo.asset, targetSize: size, contentMode: .aspectFill, options: options
            ) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    func asset(identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
}
