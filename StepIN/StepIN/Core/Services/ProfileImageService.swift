//
//  ProfileImageService.swift
//  StepIN
//
//  Stores profile photos in the app's Documents directory. SwiftData keeps
//  only the relative local path, matching the existing CV storage pattern.
//

import Foundation
import UIKit

enum ProfileImageError: LocalizedError {
    case invalidImage
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Please choose a valid image."
        case .saveFailed:
            "We couldn't save that photo. Please try again."
        }
    }
}

struct ProfileImageService {
    private let directoryName = "ProfileImages"

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func saveProfileImage(_ data: Data, for profileID: UUID) throws -> String {
        guard let image = UIImage(data: data), let jpegData = resizedJPEGData(from: image) else {
            throw ProfileImageError.invalidImage
        }

        let directory = documentsURL.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let relativePath = "\(directoryName)/profile-\(profileID.uuidString).jpg"
        let destination = documentsURL.appendingPathComponent(relativePath)

        do {
            try jpegData.write(to: destination, options: [.atomic])
            return relativePath
        } catch {
            throw ProfileImageError.saveFailed
        }
    }

    func deleteProfileImage(atLocalPath localPath: String?) {
        guard let localPath else { return }
        let url = documentsURL.appendingPathComponent(localPath)
        try? FileManager.default.removeItem(at: url)
    }

    static func image(atLocalPath localPath: String?) -> UIImage? {
        guard let localPath else { return nil }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(localPath)
        return UIImage(contentsOfFile: url.path)
    }

    private func resizedJPEGData(from image: UIImage) -> Data? {
        let maxDimension: CGFloat = 800
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > maxDimension ? maxDimension / longestSide : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return resizedImage.jpegData(compressionQuality: 0.82)
    }
}
