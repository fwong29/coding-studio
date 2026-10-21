import Photos
import UIKit

enum PhotoSaveError: LocalizedError {
    case notAuthorized
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Framewise needs permission to add photos. Enable it in Settings › Privacy › Photos."
        case .writeFailed(let reason):
            return "Couldn't save the photo: \(reason)"
        }
    }
}

/// Writes finished photos into the system Photos library.
///
/// This is the part that makes the app worth using rather than a toy: the
/// edited frame lands in the same camera roll as everything else, with no
/// export step and no share sheet.
actor PhotoSaver {

    /// Cached album identifier so we aren't re-fetching the collection on
    /// every shot.
    private var albumIdentifier: String?

    /// Asks for library access, preferring read-write so we can also keep the
    /// photos together in a named album.
    ///
    /// Add-only is enough to save, so we fall back to it rather than refusing
    /// to work: losing the album is a much smaller loss than losing the photo.
    func requestAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func save(_ capture: EditedCapture, albumName: String) async throws {
        var status = await requestAuthorization()

        if status == .notDetermined || status == .denied {
            // Try the narrower permission before giving up.
            let addOnly = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            status = addOnly == .notDetermined
                ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                : addOnly
        }

        guard status == .authorized || status == .limited else {
            throw PhotoSaveError.notAuthorized
        }

        // Only a full read-write grant lets us create and read back an album.
        // Failing to get one is not fatal — the photo still saves to the
        // camera roll, it just isn't grouped.
        var album: PHAssetCollection?
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
            album = try? await albumCollection(named: albumName)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false

                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: capture.editedData, options: options)

                if let album,
                   let placeholder = request.placeholderForCreatedAsset,
                   let albumChange = PHAssetCollectionChangeRequest(for: album) {
                    albumChange.addAssets([placeholder] as NSArray)
                }

                // The untouched camera file goes in as a separate asset when
                // the user wants a safety net. Deliberately not added to the
                // album, so the album stays the edited set.
                if let originalData = capture.originalData {
                    let originalRequest = PHAssetCreationRequest.forAsset()
                    originalRequest.addResource(with: .photo, data: originalData, options: options)
                }
            }
        } catch {
            throw PhotoSaveError.writeFailed(error.localizedDescription)
        }
    }

    /// Finds the album, creating it the first time.
    private func albumCollection(named name: String) async throws -> PHAssetCollection? {
        if let identifier = albumIdentifier {
            let existing = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier], options: nil)
            if let found = existing.firstObject { return found }
            // The user deleted it; fall through and make a new one.
            albumIdentifier = nil
        }

        // Look for one we made earlier in a previous launch.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        let matches = PHAssetCollection.fetchAssetCollections(with: .album,
                                                              subtype: .albumRegular,
                                                              options: options)
        if let found = matches.firstObject {
            albumIdentifier = found.localIdentifier
            return found
        }

        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: name)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }

        guard let placeholderID else { return nil }
        albumIdentifier = placeholderID
        return PHAssetCollection
            .fetchAssetCollections(withLocalIdentifiers: [placeholderID], options: nil)
            .firstObject
    }
}
