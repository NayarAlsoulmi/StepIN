//
//  InterviewConfiguration.swift
//  StepIN
//
//  Immutable interview context assembled by Interview Setup. Once an
//  interview starts, its configuration never changes.
//

import Foundation

struct InterviewConfiguration: Sendable {
    var jobTitle: String
    var company: String?
    var companyWebsite: String?
    var jobDescription: String?
    /// CV uploaded specifically for this interview (overrides Profile CV).
    var interviewCV: ImportedCV?
    /// Text resolved via CV priority: Interview CV → Profile CV → none.
    var resolvedCVText: String?
    var questionCount: QuestionCount
    var candidateFirstName: String

    var displayTitle: String {
        if let company, !company.isEmpty {
            "\(jobTitle) at \(company)"
        } else {
            jobTitle
        }
    }
}
