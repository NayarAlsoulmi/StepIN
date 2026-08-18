//
//  StepINEnums.swift
//  StepIN
//
//  Shared value types used across models and services.
//

import Foundation

/// Lifecycle of an interview record.
enum InterviewStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case preparing
    case inProgress
    case paused
    case analyzing
    case completed
    case failed
}

/// Status of an automatically assigned improvement goal.
enum GoalStatus: String, Codable, CaseIterable, Sendable {
    case toDo
    case completed
    case deleted
}

/// Who authored a transcript message.
enum MessageSpeaker: String, Codable, CaseIterable, Sendable {
    case interviewer
    case candidate
    case system
}

/// Allowed question counts for an interview.
enum QuestionCount: Int, Codable, CaseIterable, Identifiable, Sendable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case twenty = 20

    var id: Int { rawValue }
    var label: String { "\(rawValue)" }
}

/// The performance categories shown on the analysis screen, always in this order.
enum PerformanceCategory: String, CaseIterable, Identifiable, Sendable {
    case answerQuality = "Answer Quality"
    case clarity = "Clarity"
    case confidence = "Confidence"
    case communication = "Communication"
    case interviewSkills = "Interview Skills"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .answerQuality:
            return String(localized: "Answer Quality")
        case .clarity:
            return String(localized: "Clarity")
        case .confidence:
            return String(localized: "Confidence")
        case .communication:
            return String(localized: "Communication")
        case .interviewSkills:
            return String(localized: "Interview Skills")
        }
    }
}
