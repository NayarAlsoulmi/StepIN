//
//  CVUploadCard.swift
//  StepIN
//
//  Reusable CV upload / replace / remove card built on fileImporter.
//  Presentation + import orchestration only; the caller decides what to do
//  with the imported CV.
//

import SwiftUI
import UniformTypeIdentifiers

struct CVUploadCard: View {
    /// Currently attached CV display name, if any.
    let fileName: String?
    /// Called with the successfully imported CV.
    let onImport: (ImportedCV) -> Void
    /// Called when the user removes the current CV. Pass nil to hide Remove.
    var onRemove: (() -> Void)? = nil

    @State private var showImporter = false
    @State private var isImporting = false
    @State private var importErrorMessage: String?

    private let service = CVDocumentService()

    var body: some View {
        StepINCard {
            VStack(alignment: .leading, spacing: StepINSpacing.sm) {
                HStack(spacing: StepINSpacing.md) {
                    Image(systemName: fileName == nil ? "doc.badge.plus" : "doc.text.fill")
                        .font(.system(size: 24))
                        .foregroundColor(StepINColor.primary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName ?? "Upload CV")
                            .font(StepINFont.body2)
                            .foregroundColor(StepINColor.textPrimary)
                            .lineLimit(1)
                        Text(fileName == nil
                             ? "PDF or text · optional"
                             : "Tap to replace")
                            .font(StepINFont.caption)
                            .foregroundColor(StepINColor.textSecondary)
                    }

                    Spacer()

                    if isImporting {
                        ProgressView()
                    } else if fileName != nil, let onRemove {
                        Button {
                            onRemove()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(StepINColor.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove CV")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showImporter = true }

                if let importErrorMessage {
                    Text(importErrorMessage)
                        .font(StepINFont.caption)
                        .foregroundColor(StepINColor.error)
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fileName == nil ? "Upload CV, optional" : "CV attached: \(fileName!)")
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importErrorMessage = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        // PDF parsing is fast for typical CVs but keep it off the main actor.
        Task.detached(priority: .userInitiated) {
            do {
                let imported = try service.importCV(from: url)
                await MainActor.run {
                    isImporting = false
                    onImport(imported)
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importErrorMessage = error.localizedDescription
                }
            }
        }
    }
}
