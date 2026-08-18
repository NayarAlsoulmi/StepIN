//
//  OpenAIConfiguration.swift
//  StepIN
//
//  Reads development-only OpenAI configuration injected by Xcode build settings.
//  The key is never logged, persisted, or exposed to UI.
//

import Foundation

enum OpenAIConfiguration {
    static var apiKey: String? {
        for key in ["OPENAI_API_KEY", "OpenAIAPIKey"] {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
                continue
            }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("$(OPENAI_API_KEY)") else {
                continue
            }
            return trimmed
        }

        #if DEBUG
        return apiKeyFromDevelopmentConfigFile()
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static func apiKeyFromDevelopmentConfigFile() -> String? {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let configURL = projectRoot.appendingPathComponent("Secrets.xcconfig")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, parts[0] == "OPENAI_API_KEY" else { continue }
            let value = parts[1]
            guard !value.isEmpty else { return nil }
            return value
        }

        return nil
    }
    #endif

    static var hasDevelopmentAPIKey: Bool {
        apiKey != nil
    }
}
