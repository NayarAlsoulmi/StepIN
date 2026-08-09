//
//  StepINModels.swift
//  StepIN
//
//  SwiftData persistence models. All user data stays local (version one).
//  Large files (CVs, audio) are stored on disk via FileManager; only paths
//  live in SwiftData.
//

import Foundation
import SwiftData

// MARK: - UserProfile

@Model
final class UserProfile {
    @Attribute(.unique) var id: UUID
    var firstName: String
    var lastName: String?
    var email: String?
    var profileCVFileName: String?
    var profileCVLocalPath: String?
    var profileCVExtractedText: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        firstName: String,
        lastName: String? = nil,
        email: String? = nil,
        profileCVFileName: String? = nil,
        profileCVLocalPath: String? = nil,
        profileCVExtractedText: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.profileCVFileName = profileCVFileName
        self.profileCVLocalPath = profileCVLocalPath
        self.profileCVExtractedText = profileCVExtractedText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var hasCV: Bool { profileCVLocalPath != nil }
}

// MARK: - InterviewRecord

@Model
final class InterviewRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var jobTitle: String
    var company: String?
    var companyWebsite: String?
    var jobDescription: String?
    var interviewCVFileName: String?
    var interviewCVLocalPath: String?
    var resolvedCVText: String?
    var selectedQuestionCount: Int
    var completedQuestionCount: Int
    var startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval
    var overallScore: Int?
    var isPartial: Bool
    var statusRaw: String

    @Relationship(deleteRule: .cascade, inverse: \InterviewMessage.interview)
    var transcript: [InterviewMessage]

    @Relationship(deleteRule: .cascade, inverse: \InterviewAnalysis.interview)
    var analysis: InterviewAnalysis?

    var status: InterviewStatus {
        get { InterviewStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        jobTitle: String,
        company: String? = nil,
        companyWebsite: String? = nil,
        jobDescription: String? = nil,
        interviewCVFileName: String? = nil,
        interviewCVLocalPath: String? = nil,
        resolvedCVText: String? = nil,
        selectedQuestionCount: Int,
        completedQuestionCount: Int = 0,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        duration: TimeInterval = 0,
        overallScore: Int? = nil,
        isPartial: Bool = false,
        status: InterviewStatus = .draft
    ) {
        self.id = id
        self.title = title
        self.jobTitle = jobTitle
        self.company = company
        self.companyWebsite = companyWebsite
        self.jobDescription = jobDescription
        self.interviewCVFileName = interviewCVFileName
        self.interviewCVLocalPath = interviewCVLocalPath
        self.resolvedCVText = resolvedCVText
        self.selectedQuestionCount = selectedQuestionCount
        self.completedQuestionCount = completedQuestionCount
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.overallScore = overallScore
        self.isPartial = isPartial
        self.statusRaw = status.rawValue
        self.transcript = []
        self.analysis = nil
    }

    /// Transcript with system messages removed, in chronological order.
    var visibleTranscript: [InterviewMessage] {
        transcript
            .filter { $0.speaker != .system }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
    }
}

// MARK: - InterviewMessage

@Model
final class InterviewMessage {
    @Attribute(.unique) var id: UUID
    var speakerRaw: String
    var text: String
    var createdAt: Date
    var sequenceNumber: Int
    var audioDuration: TimeInterval?
    /// Aggregated speech metadata, JSON-encoded. Never exposed raw to the user.
    var speechMetadata: Data?

    var interview: InterviewRecord?

    var speaker: MessageSpeaker {
        get { MessageSpeaker(rawValue: speakerRaw) ?? .system }
        set { speakerRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        speaker: MessageSpeaker,
        text: String,
        sequenceNumber: Int,
        createdAt: Date = .now,
        audioDuration: TimeInterval? = nil,
        speechMetadata: Data? = nil
    ) {
        self.id = id
        self.speakerRaw = speaker.rawValue
        self.text = text
        self.sequenceNumber = sequenceNumber
        self.createdAt = createdAt
        self.audioDuration = audioDuration
        self.speechMetadata = speechMetadata
    }
}

// MARK: - InterviewAnalysis

@Model
final class InterviewAnalysis {
    @Attribute(.unique) var id: UUID
    var overallScore: Int
    var answerQualityScore: Int
    var clarityScore: Int
    var confidenceScore: Int
    var communicationScore: Int
    var interviewSkillsScore: Int
    var strengths: [String]
    var areasToImprove: [String]
    var summary: String
    var createdAt: Date

    var interview: InterviewRecord?

    init(
        id: UUID = UUID(),
        overallScore: Int,
        answerQualityScore: Int,
        clarityScore: Int,
        confidenceScore: Int,
        communicationScore: Int,
        interviewSkillsScore: Int,
        strengths: [String],
        areasToImprove: [String],
        summary: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.overallScore = overallScore
        self.answerQualityScore = answerQualityScore
        self.clarityScore = clarityScore
        self.confidenceScore = confidenceScore
        self.communicationScore = communicationScore
        self.interviewSkillsScore = interviewSkillsScore
        self.strengths = strengths
        self.areasToImprove = areasToImprove
        self.summary = summary
        self.createdAt = createdAt
    }

    /// Category scores paired with their display label, always in canonical order.
    var categoryScores: [(category: PerformanceCategory, score: Int)] {
        [
            (.answerQuality, answerQualityScore),
            (.clarity, clarityScore),
            (.confidence, confidenceScore),
            (.communication, communicationScore),
            (.interviewSkills, interviewSkillsScore)
        ]
    }
}

// MARK: - AssignedGoal

/// Standalone model: goals intentionally are NOT a cascade child of an
/// interview, so deleting an interview never deletes its goals.
@Model
final class AssignedGoal {
    @Attribute(.unique) var id: UUID
    var interviewID: UUID
    var title: String
    var sourceInterviewTitle: String
    var sourceJobTitle: String
    var sourceCompany: String?
    var createdAt: Date
    var completedAt: Date?
    var statusRaw: String

    var status: GoalStatus {
        get { GoalStatus(rawValue: statusRaw) ?? .toDo }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        interviewID: UUID,
        title: String,
        sourceInterviewTitle: String,
        sourceJobTitle: String,
        sourceCompany: String? = nil,
        createdAt: Date = .now,
        completedAt: Date? = nil,
        status: GoalStatus = .toDo
    ) {
        self.id = id
        self.interviewID = interviewID
        self.title = title
        self.sourceInterviewTitle = sourceInterviewTitle
        self.sourceJobTitle = sourceJobTitle
        self.sourceCompany = sourceCompany
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.statusRaw = status.rawValue
    }

    /// User-facing source line, e.g. "From UX Design Interview". Used
    /// everywhere a goal shows where it came from — keep the format
    /// consistent across Home and My Goals.
    var sourceLabel: String {
        "From \(sourceInterviewTitle)"
    }
}

// MARK: - ActiveInterviewDraft

/// Lightweight recovery snapshot for an in-progress interview.
@Model
final class ActiveInterviewDraft {
    @Attribute(.unique) var id: UUID
    var interviewID: UUID
    var currentQuestion: String?
    var completedQuestionCount: Int
    var selectedQuestionCount: Int
    var closingQuestionAsked: Bool
    var isPaused: Bool
    var lastSavedAt: Date

    init(
        id: UUID = UUID(),
        interviewID: UUID,
        currentQuestion: String? = nil,
        completedQuestionCount: Int = 0,
        selectedQuestionCount: Int,
        closingQuestionAsked: Bool = false,
        isPaused: Bool = false,
        lastSavedAt: Date = .now
    ) {
        self.id = id
        self.interviewID = interviewID
        self.currentQuestion = currentQuestion
        self.completedQuestionCount = completedQuestionCount
        self.selectedQuestionCount = selectedQuestionCount
        self.closingQuestionAsked = closingQuestionAsked
        self.isPaused = isPaused
        self.lastSavedAt = lastSavedAt
    }
}

// MARK: - Schema

enum StepINSchema {
    static let models: [any PersistentModel.Type] = [
        UserProfile.self,
        InterviewRecord.self,
        InterviewMessage.self,
        InterviewAnalysis.self,
        AssignedGoal.self,
        ActiveInterviewDraft.self
    ]
}
