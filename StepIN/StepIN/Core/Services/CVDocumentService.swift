//
//  CVDocumentService.swift
//  StepIN
//
//  Imports CV files into the app's Documents directory and extracts plain
//  text (PDF via PDFKit, plain text directly). Extracted text is cached on
//  the owning model; extraction happens once per import.
//

import Foundation
import PDFKit

/// Result of a successful CV import.
struct ImportedCV: Sendable {
    let fileName: String       // Original display name
    let localPath: String      // Path relative to Documents
    let extractedText: String
}

enum CVImportError: LocalizedError {
    case unsupportedType
    case copyFailed
    case noExtractableText

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            "This file type isn't supported. Please choose a PDF or text file."
        case .copyFailed:
            "We couldn't import that file. Please try again."
        case .noExtractableText:
            "We couldn't read any text from that file. You can try another file or continue without a CV."
        }
    }
}

struct CVDocumentService {

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Copies the picked file into Documents under a unique name and
    /// extracts its text. `sourceURL` comes from fileImporter and is
    /// security-scoped.
    func importCV(from sourceURL: URL) throws -> ImportedCV {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.lowercased()
        guard ["pdf", "txt", "text"].contains(ext) else {
            throw CVImportError.unsupportedType
        }

        // Unique destination name; original name kept for display.
        let uniqueName = "cv-\(UUID().uuidString).\(ext)"
        let destination = documentsURL.appendingPathComponent(uniqueName)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw CVImportError.copyFailed
        }

        let text: String
        do {
            text = try extractText(from: destination, fileExtension: ext)
        } catch {
            // Clean up the copy if we can't use it.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        return ImportedCV(
            fileName: sourceURL.lastPathComponent,
            localPath: uniqueName,
            extractedText: text
        )
    }

    /// Deletes a previously imported CV file. Missing files are ignored.
    func deleteCV(atLocalPath localPath: String) {
        let url = documentsURL.appendingPathComponent(localPath)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Text extraction

    private func extractText(from url: URL, fileExtension: String) throws -> String {
        let raw: String
        switch fileExtension {
        case "pdf":
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                throw CVImportError.noExtractableText
            }
            raw = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
        default:
            raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        let normalized = normalize(raw)
        guard !normalized.isEmpty else { throw CVImportError.noExtractableText }
        return normalized
    }

    /// Collapse repeated whitespace while keeping paragraph breaks readable.
    private func normalize(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines {
            // Drop runs of blank lines.
            if line.isEmpty && result.last?.isEmpty == true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
