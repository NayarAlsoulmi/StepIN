//
//  InterviewOrchestration.swift
//  StepIN
//
//  Lightweight interview intelligence: Swift decides what should be covered;
//  the realtime model decides how to phrase each question naturally.
//

import Foundation

struct InterviewContext: Sendable {
    let jobTitle: String
    let company: String?
    let jobDescription: String?
    let cvText: String?
    let questionCount: Int
    let candidateFirstName: String
    let candidateLevel: String?
    let cvAnchors: [InterviewAnchor]
    let jdAnchors: [InterviewAnchor]

    init(configuration: InterviewConfiguration) {
        jobTitle = configuration.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        company = configuration.company.orchestrationNilIfBlank
        jobDescription = configuration.jobDescription.orchestrationNilIfBlank
        cvText = configuration.resolvedCVText.orchestrationNilIfBlank
        questionCount = configuration.questionCount.rawValue
        candidateFirstName = configuration.candidateFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        cvAnchors = InterviewAnchorExtractor.cvAnchors(from: cvText, candidateFirstName: candidateFirstName)
        jdAnchors = InterviewAnchorExtractor.jdAnchors(from: jobDescription)
        candidateLevel = InterviewAnchorExtractor.candidateLevel(cvText: cvText, jobDescription: jobDescription)
    }

    var hasCV: Bool { !cvAnchors.isEmpty }
    var hasJD: Bool { !jdAnchors.isEmpty }
}

struct InterviewAnchor: Sendable, Equatable, Hashable {
    enum Source: String, Sendable {
        case cv = "CV"
        case jobDescription = "JD"
        case company = "Company"
        case role = "Role"
        case adaptive = "Adaptive"
    }

    enum Kind: String, Sendable {
        case project = "PROJECT"
        case experience = "EXPERIENCE"
        case achievement = "ACHIEVEMENT"
        case skill = "SKILL"
        case responsibility = "RESPONSIBILITY"
        case technology = "TECHNOLOGY"
        case jdRequirement = "JD_REQUIREMENT"
        case roleContext = "ROLE_CONTEXT"
        case unknown = "UNKNOWN"
    }

    let source: Source
    let kind: Kind
    let title: String
    let detail: String
    let keywords: [String]

    var promptLine: String {
        let keywordText = keywords.isEmpty ? "" : " Keywords: \(keywords.prefix(6).joined(separator: ", "))."
        return "\(source.rawValue) \(kind.rawValue): \(title). \(detail)\(keywordText)"
    }
}

enum InterviewCoverageDimension: String, Sendable {
    case contextualOpening = "background/relevant experience"
    case cvExperience = "CV/project experience"
    case roleSpecific = "role-specific competency"
    case behavioral = "behavioral competency"
    case technical = "technical/domain competency"
    case jdRequirement = "job-description requirement"
    case collaboration = "collaboration/communication"
    case motivation = "role/company motivation"
    case ownership = "ownership/decision-making"
    case adaptability = "adaptability/learning"
    case adaptiveFollowUp = "adaptive follow-up"
    case closingSubstantive = "closing substantive question"
}

struct QuestionTarget: Sendable, Equatable {
    enum TurnKind: String, Sendable {
        case newTopic = "NEW_TOPIC"
        case followUp = "FOLLOW_UP"
    }

    let dimension: InterviewCoverageDimension
    let anchor: InterviewAnchor?
    let competency: String
    let turnKind: TurnKind
    let allowFollowUp: Bool
    let forbiddenAnchors: [String]

    var anchorKey: String {
        anchor.map { CVAnchorSelector.groupKey(for: $0) } ?? "dimension:\(dimension.rawValue)"
    }

    var anchorTitle: String {
        anchor?.title ?? dimension.rawValue
    }
}

struct InterviewCoverageTarget: Identifiable, Sendable, Equatable {
    let id: UUID
    let dimension: InterviewCoverageDimension
    let intent: String
    let anchor: InterviewAnchor?
    let maxFollowUps: Int

    init(
        id: UUID = UUID(),
        dimension: InterviewCoverageDimension,
        intent: String,
        anchor: InterviewAnchor? = nil,
        maxFollowUps: Int
    ) {
        self.id = id
        self.dimension = dimension
        self.intent = intent
        self.anchor = anchor
        self.maxFollowUps = maxFollowUps
    }

    var debugLabel: String {
        if let anchor {
            return "\(dimension.rawValue) | \(intent) | \(anchor.source.rawValue): \(anchor.title)"
        }
        return "\(dimension.rawValue) | \(intent)"
    }
}

struct InterviewPlan: Sendable {
    let context: InterviewContext
    let targets: [InterviewCoverageTarget]
    let openingTargetID: UUID
    let openingCandidateCount: Int
    let blueprintPatternKey: String

    var openingTarget: InterviewCoverageTarget {
        targets.first { $0.id == openingTargetID } ?? targets[0]
    }
}

enum AnswerRelevance: String, Sendable {
    case relevant = "RELEVANT"
    case partiallyRelevant = "PARTIALLY_RELEVANT"
    case offTopic = "OFF_TOPIC"
    case nonAnswer = "NON_ANSWER"
    case nonsenseOrFiller = "NONSENSE_OR_FILLER"

    var containsInterviewEvidence: Bool {
        self == .relevant || self == .partiallyRelevant
    }
}

enum InterviewNextAction: Sendable {
    case firstQuestion(InterviewCoverageTarget)
    case followUp(InterviewCoverageTarget, AnswerRelevance)
    case nextTarget(InterviewCoverageTarget, AnswerRelevance)
    case redirect(InterviewCoverageTarget, AnswerRelevance)
    case closingOpportunity
    case finalClose

    var countsTowardTotal: Bool {
        switch self {
        case .firstQuestion, .followUp, .nextTarget:
            return true
        case .redirect, .closingOpportunity, .finalClose:
            return false
        }
    }

    var isFinalClose: Bool {
        if case .finalClose = self { return true }
        return false
    }

    var coverageTarget: InterviewCoverageTarget? {
        switch self {
        case .firstQuestion(let target), .followUp(let target, _), .nextTarget(let target, _), .redirect(let target, _):
            return target
        case .closingOpportunity, .finalClose:
            return nil
        }
    }

    var isFollowUpTurn: Bool {
        if case .followUp = self { return true }
        return false
    }

    var isFirstQuestion: Bool {
        if case .firstQuestion = self { return true }
        return false
    }
}

enum GeneratedQuestionDecision: Sendable, Equatable {
    case accepted
    case retry(String)
    case fallback(String)
}

private enum InterviewAcknowledgmentMode: String, Sendable {
    case none = "NONE"
    case neutral = "NEUTRAL"
    case contextual = "CONTEXTUAL"
}

@MainActor
final class InterviewConversationController {
    private static let maxQuestionsPerAnchor = 2
    private static let maxConsecutiveFollowUps = 1
    private static let maxGenerationAttempts = 2

    private let plan: InterviewPlan
    private var targetIndex: Int
    private var coveredTargetIDs: Set<UUID> = []
    private var followUpDepthByTargetID: [UUID: Int] = [:]
    private var questionUsageByTopicGroup: [String: Int] = [:]
    private var lastTargetID: UUID?
    private var lastRelevance: AnswerRelevance = .relevant
    private var closingOpportunityAsked = false
    private var completedSubstantiveQuestions = 0
    /// Evidence group of the most recently asked question. Updated on every
    /// topic transition so instructions(for:) knows what was just covered.
    private var lastTopicGroup: String? = nil
    /// Evidence group that was active just before the last topic transition.
    /// Passed into the per-turn instruction as an explicit forbidden subject
    /// when the planner moves to a new dimension.
    private var previousTopicGroup: String? = nil
    /// Number of consecutive follow-up turns on the current topic. Reset to 0
    /// whenever the controller transitions to a genuinely new target.
    private var consecutiveFollowUpCount: Int = 0
    private var currentAnchor: String? = nil
    private var previousAnchor: String? = nil
    private var questionsPerAnchor: [String: Int] = [:]
    private var exhaustedAnchors: Set<String> = []
    private var recentQuestionAnchors: [String] = []
    private var previousInterviewerQuestions: [String] = []
    private var generationAttemptByTargetID: [UUID: Int] = [:]
    private var activeQuestionTarget: QuestionTarget? = nil
    private var activeQuestionAction: InterviewNextAction? = nil
    /// CV anchor title that the candidate most recently introduced in their own
    /// answer (e.g. they mentioned a project by name answering a generic question).
    /// Used to guard NEXT_TARGET instructions so the model does not re-introduce
    /// that project as the frame for the next unrelated dimension.
    private var lastCandidateIntroducedCVTopic: String? = nil

    init(configuration: InterviewConfiguration) {
        let context = InterviewContext(configuration: configuration)
        let madePlan = InterviewPlanner.makePlan(context: context)
        self.plan = madePlan
        self.targetIndex = madePlan.targets.firstIndex { $0.id == madePlan.openingTargetID } ?? 0
        logPlan()
    }

    var substantiveQuestionCount: Int { completedSubstantiveQuestions }

    func openingAction() -> InterviewNextAction {
        let target = plan.openingTarget
        targetIndex = plan.targets.firstIndex(of: target) ?? targetIndex
        lastTargetID = target.id
        lastTopicGroup = target.topicGroup
        currentAnchor = target.topicGroup
        previousTopicGroup = nil
        scheduleQuestionTarget(for: .firstQuestion(target))
        logCurrent(action: "opening", target: target, relevance: nil)
        return .firstQuestion(target)
    }

    func nextAction(after answer: String, countedQuestionCount: Int) -> InterviewNextAction {
        completedSubstantiveQuestions = countedQuestionCount
        let relevance = AnswerRelevanceClassifier.classify(answer)
        lastRelevance = relevance

        if closingOpportunityAsked {
            logCurrent(action: "final_close", target: currentTarget, relevance: relevance)
            return .finalClose
        }

        guard countedQuestionCount < plan.context.questionCount else {
            closingOpportunityAsked = true
            logCurrent(action: "closing_opportunity", target: currentTarget, relevance: relevance)
            return .closingOpportunity
        }

        let active = currentTarget
        if !relevance.containsInterviewEvidence {
            logCurrent(action: "redirect", target: active, relevance: relevance)
            return .redirect(active, relevance)
        }

        if shouldFollowUp(answer: answer, relevance: relevance, countedQuestionCount: countedQuestionCount, target: active) {
            let depth = (followUpDepthByTargetID[active.id] ?? 0) + 1
            followUpDepthByTargetID[active.id] = depth
            consecutiveFollowUpCount += 1
            // Track what the candidate just mentioned so we can guard the NEXT non-CV target.
            lastCandidateIntroducedCVTopic = extractCandidateIntroducedCVTopic(from: answer)
            lastTargetID = active.id
            scheduleQuestionTarget(for: .followUp(active, relevance))
            logCurrent(action: "follow_up", target: active, relevance: relevance)
            return .followUp(active, relevance)
        }

        let next = nextUncoveredTarget(after: active) ?? active
        consecutiveFollowUpCount = 0
        lastCandidateIntroducedCVTopic = extractCandidateIntroducedCVTopic(from: answer)
        previousTopicGroup = lastTopicGroup
        previousAnchor = currentAnchor
        lastTopicGroup = next.topicGroup
        currentAnchor = next.topicGroup
        targetIndex = plan.targets.firstIndex(of: next) ?? targetIndex
        lastTargetID = next.id
        scheduleQuestionTarget(for: .nextTarget(next, relevance))
        logTransition(previousTopicGroup: previousTopicGroup, newTarget: next, transitionType: "NEW_TOPIC")
        logCurrent(action: "next_target", target: next, relevance: relevance)
        return .nextTarget(next, relevance)
    }

    func validateGeneratedQuestion(counted: Bool, text: String, language: String) -> GeneratedQuestionDecision {
        guard counted, let action = activeQuestionAction, let target = action.coverageTarget else {
            return .accepted
        }

        let questionTarget = activeQuestionTarget ?? concreteQuestionTarget(for: action)
        let validation = GeneratedQuestionValidator.validate(
            question: text,
            target: questionTarget,
            previousAnchor: previousAnchor,
            previousQuestions: previousInterviewerQuestions,
            exhaustedAnchors: exhaustedAnchors,
            knownCVAnchors: plan.context.cvAnchors,
            isFollowUp: action.isFollowUpTurn,
            isFirstQuestion: action.isFirstQuestion
        )
        let attempt = (generationAttemptByTargetID[target.id] ?? 0) + 1
        generationAttemptByTargetID[target.id] = attempt
        logQuestionRuntime(
            target: target,
            questionTarget: questionTarget,
            attempt: attempt,
            generatedQuestion: text,
            validation: validation,
            finalAcceptedQuestion: validation.isValid ? text : nil
        )
        logOpeningQuestionIfNeeded(
            action: action,
            questionTarget: questionTarget,
            generatedQuestion: text,
            validation: validation
        )

        if validation.isValid {
            return .accepted
        }

        if attempt < Self.maxGenerationAttempts {
            return .retry(regenerationInstruction(for: action, language: language, rejectionReason: validation.reason))
        }

        let fallback = fallbackQuestion(for: questionTarget, language: language)
        logQuestionRuntime(
            target: target,
            questionTarget: questionTarget,
            attempt: attempt + 1,
            generatedQuestion: fallback,
            validation: .valid,
            finalAcceptedQuestion: fallback
        )
        logOpeningQuestionIfNeeded(
            action: action,
            questionTarget: questionTarget,
            generatedQuestion: fallback,
            validation: .valid
        )
        return .fallback(fallback)
    }

    /// Cheap check against partial transcript — anchor mention + dimension keywords only.
    /// Returns true if it's safe to release buffered audio now without waiting for the full text.
    /// Full validation still runs at transcript.done for duplicate/exhausted-anchor checks.
    func earlyValidateGeneratedQuestion(partial: String) -> Bool {
        guard let action = activeQuestionAction, action.coverageTarget != nil else {
            return true
        }
        // For the first question the candidate has not spoken yet. Block audio release early
        // if the partial text already contains acknowledgment language implying a prior answer,
        // so the full validator can trigger regeneration before any audio plays.
        if action.isFirstQuestion, GeneratedQuestionValidator.containsPreviousContextLanguage(partial) {
            return false
        }
        let questionTarget = activeQuestionTarget ?? concreteQuestionTarget(for: action)
        return GeneratedQuestionValidator.partiallyValidate(
            partialQuestion: partial,
            target: questionTarget,
            exhaustedAnchors: exhaustedAnchors,
            knownCVAnchors: plan.context.cvAnchors
        )
    }

    func markAssistantTurnCompleted(counted: Bool, text: String) {
        if counted {
            completedSubstantiveQuestions = min(completedSubstantiveQuestions + 1, plan.context.questionCount)
        }

        guard let lastTargetID else { return }
        if counted, let target = plan.targets.first(where: { $0.id == lastTargetID }) {
            markCovered(target)
            let group = target.topicGroup
            questionUsageByTopicGroup[group, default: 0] += 1
            questionsPerAnchor[group, default: 0] += 1
            recentQuestionAnchors.append(group)
            if recentQuestionAnchors.count > 2 { recentQuestionAnchors.removeFirst(recentQuestionAnchors.count - 2) }
            if questionsPerAnchor[group, default: 0] >= Self.maxQuestionsPerAnchor {
                exhaustedAnchors.insert(group)
            }
            previousInterviewerQuestions.append(text)
            if previousInterviewerQuestions.count > 12 {
                previousInterviewerQuestions.removeFirst(previousInterviewerQuestions.count - 12)
            }
        }
    }

    func instructions(for action: InterviewNextAction, language: String) -> String {
        switch action {
        case .firstQuestion(let target):
            logQuestionGeneration(target: target, isFollowUp: false, topicChanged: false)
            return questionInstruction(
                prefix: "Ask the first real counted interview question now",
                target: target,
                language: language,
                acknowledgmentMode: .none,
                extra: "Use this opening intent to avoid generic repeated openers. Do not greet again. This is the FIRST interview question. The candidate has not answered any interview question yet. Do not acknowledge, summarize, reference, or imply any previous candidate answer. Do not say \"next question\", \"moving on\", \"thank you for sharing\", \"you mentioned\", or any equivalent continuation language. Ask one standalone interview question only.",
                forbiddenEvidenceGroup: nil
            )

        case .followUp(let target, let relevance):
            let reasonLine: String
            if relevance == .partiallyRelevant {
                reasonLine = "The previous answer did not fully address the question. Ask one specific follow-up to get a more complete or on-target response."
            } else {
                reasonLine = "The previous answer was brief or lacked sufficient clarity. Ask one focused follow-up to get a clearer picture of the candidate's experience or thinking."
            }
            logQuestionGeneration(target: target, isFollowUp: true, topicChanged: false)
            return questionInstruction(
                prefix: "Ask a counted follow-up question",
                target: target,
                language: language,
                acknowledgmentMode: .none,
                extra: "\(reasonLine) Ask one targeted question only. Do not drill beyond this target's follow-up budget.",
                forbiddenEvidenceGroup: nil
            )

        case .nextTarget(let target, let relevance):
            let topicChanged = previousTopicGroup != nil && previousTopicGroup != target.topicGroup
            // Pass the candidate-introduced topic only when the new target is NOT CV-anchored,
            // to avoid forbidding a project we intentionally selected.
            let candidateTopic: String? = (target.anchor?.source != .cv) ? lastCandidateIntroducedCVTopic : nil
            let transitionLine: String
            if topicChanged {
                let prevLabel = previousTopicGroup ?? "previous topic"
                transitionLine = "NEW INTERVIEW TOPIC. Do NOT continue the previous subject (\(prevLabel)). Ask a completely standalone question about \(target.dimension.rawValue) that would make sense as the very first question of a different interview. Standalone test: if the candidate's previous answer were deleted, this question must still make complete sense. If your draft is appropriate as a follow-up to something said before, rephrase it."
            } else if relevance == .partiallyRelevant {
                transitionLine = "The candidate's last answer was incomplete. Move to this new target directly. Standalone test: the question must make complete sense without the previous answer."
            } else {
                transitionLine = "Move directly to this new topic. Do not reference, summarize, or build on the previous answer. Standalone test: the question must make complete sense even if the candidate's previous answer were removed."
            }
            logQuestionGeneration(target: target, isFollowUp: false, topicChanged: topicChanged)
            return questionInstruction(
                prefix: "Move to the next counted coverage target",
                target: target,
                language: language,
                acknowledgmentMode: .none,
                extra: "\(transitionLine) Ask one question only.",
                forbiddenEvidenceGroup: topicChanged ? previousTopicGroup : nil,
                forbiddenCandidateTopic: candidateTopic
            )

        case .redirect(let target, let relevance):
            let redirect = relevance == .nonAnswer || relevance == .nonsenseOrFiller
                ? "The candidate did not provide a usable interview answer. Give one brief clarification or repeat the question in a clearer form."
                : "The candidate went off topic. Do not answer their unrelated request. Briefly redirect to the interview."
            return questionInstruction(
                prefix: "Redirect without spending a counted question",
                target: target,
                language: language,
                acknowledgmentMode: .none,
                extra: "\(redirect) Do not say this was helpful context unless it contained real interview content. Keep it short and professional.",
                forbiddenEvidenceGroup: nil
            )

        case .closingOpportunity:
            return """
            \(languageLockInstruction(for: language))
            Ask only the existing uncounted closing opportunity in \(language): \(closingOpportunityText(for: language)) Do not ask a new scored interview question. Stop after the closing opportunity and wait.
            """

        case .finalClose:
            return """
            \(languageLockInstruction(for: language))
            Say exactly this closing in \(language): \(finalCloseText(for: language)) Do not add any other sentence, question, feedback, score, or commentary.
            """
        }
    }

    private var currentTarget: InterviewCoverageTarget {
        plan.targets[min(max(targetIndex, 0), plan.targets.count - 1)]
    }

    private func scheduleQuestionTarget(for action: InterviewNextAction) {
        activeQuestionAction = action
        activeQuestionTarget = concreteQuestionTarget(for: action)
        if let target = action.coverageTarget {
            generationAttemptByTargetID[target.id] = 0
        }
    }

    private func concreteQuestionTarget(for action: InterviewNextAction) -> QuestionTarget {
        let target = action.coverageTarget ?? currentTarget
        let forbidden = Array(exhaustedAnchors.union(Set(recentQuestionAnchors.count == 2 && recentQuestionAnchors[0] == recentQuestionAnchors[1] ? [recentQuestionAnchors[0]] : [])))
        return QuestionTarget(
            dimension: target.dimension,
            anchor: target.anchor,
            competency: competency(for: target),
            turnKind: action.isFollowUpTurn ? .followUp : .newTopic,
            allowFollowUp: action.isFollowUpTurn,
            forbiddenAnchors: forbidden
        )
    }

    private func competency(for target: InterviewCoverageTarget) -> String {
        switch target.dimension {
        case .cvExperience:
            return "technical problem solving and evidence of contribution"
        case .roleSpecific:
            return "role readiness"
        case .behavioral:
            return "problem solving and judgment"
        case .technical:
            return "technical/domain decision quality"
        case .jdRequirement:
            return "job-description requirement fit"
        case .collaboration:
            return "teamwork and communication"
        case .motivation:
            return "motivation and role fit"
        case .ownership:
            return "ownership and accountability"
        case .adaptability:
            return "learning and adaptability"
        case .contextualOpening:
            return "relevant background"
        case .adaptiveFollowUp:
            return "clarification from the immediately previous answer"
        case .closingSubstantive:
            return "final role-relevant evidence"
        }
    }

    private func regenerationInstruction(
        for action: InterviewNextAction,
        language: String,
        rejectionReason: String
    ) -> String {
        let base = instructions(for: action, language: language)
        return """
        \(base)

        REGENERATION REQUIRED BY SWIFT VALIDATION.
        Rejection reason: \(rejectionReason)
        Keep the same selected QuestionTarget. Do not choose a different topic, anchor, project, or competency. Ask one valid question only.
        """
    }

    private func fallbackQuestion(for target: QuestionTarget, language: String) -> String {
        if language == "Arabic" {
            return arabicFallbackQuestion(for: target)
        }

        let anchor = target.anchorTitle
        switch target.dimension {
        case .cvExperience:
            let evidenceKinds: [InterviewAnchor.Kind] = [.project, .experience, .achievement, .responsibility, .skill, .technology]
            if let kind = target.anchor?.kind, evidenceKinds.contains(kind) {
                return "For \(anchor), what was your specific contribution, and what decision or trade-off had the biggest impact?"
            }
            return "Tell me about a piece of work you're most proud of — what did you build or contribute to, and what was the outcome?"
        case .roleSpecific:
            return "For the \(plan.context.jobTitle) role, what is one concrete example that shows you are ready for this responsibility?"
        case .behavioral:
            return "Tell me about a time you solved a difficult problem, and how you decided what to do."
        case .technical:
            return "What technical trade-off have you had to make in work or a project, and how did you evaluate it?"
        case .jdRequirement:
            return "The role calls for \(anchor). What experience do you have that best demonstrates that capability?"
        case .collaboration:
            return "Tell me about a time you worked closely with a team to reach a shared outcome."
        case .motivation:
            if let company = plan.context.company {
                return "What specifically motivates you about this \(plan.context.jobTitle) opportunity at \(company)?"
            }
            return "What specifically motivates you about this \(plan.context.jobTitle) opportunity?"
        case .ownership:
            return "Tell me about a time you took ownership of a difficult decision or outcome."
        case .adaptability:
            return "Tell me about a time you had to learn or adjust quickly when the situation changed."
        case .contextualOpening:
            return "What part of your background is most relevant to this \(plan.context.jobTitle) role?"
        case .adaptiveFollowUp:
            return "What was the most important decision you made in that situation, and why?"
        case .closingSubstantive:
            return "What is one strength you would bring to this role that we have not discussed yet?"
        }
    }

    private func arabicFallbackQuestion(for target: QuestionTarget) -> String {
        switch target.dimension {
        case .cvExperience:
            let evidenceKinds: [InterviewAnchor.Kind] = [.project, .experience, .achievement, .responsibility, .skill, .technology]
            if let kind = target.anchor?.kind, evidenceKinds.contains(kind) {
                return "بالنسبة إلى \(target.anchorTitle)، ما مساهمتك المحددة، وما القرار أو المفاضلة التي كان لها أكبر أثر؟"
            }
            return "حدثني عن عمل أو مشروع تفتخر به، ماذا بنيت أو أسهمت فيه، وما كانت النتيجة؟"
        case .collaboration:
            return "حدثني عن موقف عملت فيه مع فريق للوصول إلى نتيجة مشتركة."
        case .motivation:
            return "ما الذي يحفزك تحديدا لهذه الفرصة في دور \(plan.context.jobTitle)؟"
        default:
            return "حدثني عن مثال عملي يوضح \(target.competency) المناسب لدور \(plan.context.jobTitle)."
        }
    }

    private func shouldFollowUp(
        answer: String,
        relevance: AnswerRelevance,
        countedQuestionCount: Int,
        target: InterviewCoverageTarget
    ) -> Bool {
        // --- Hard gates ---
        guard relevance.containsInterviewEvidence else {
            logFollowUpDecision(target: target, answerProfile: nil,
                remainingSlots: plan.context.questionCount - countedQuestionCount,
                decision: false, reason: "answer_has_no_interview_evidence")
            return false
        }
        let remainingSlots = plan.context.questionCount - countedQuestionCount
        guard consecutiveFollowUpCount < Self.maxConsecutiveFollowUps else {
            logFollowUpDecision(target: target, answerProfile: nil,
                remainingSlots: remainingSlots,
                decision: false, reason: "consecutive_follow_up_limit_reached")
            return false
        }
        guard remainingSlots > remainingRequiredTargets(after: target) else {
            logFollowUpDecision(target: target, answerProfile: nil,
                remainingSlots: remainingSlots,
                decision: false, reason: "coverage_budget_requires_next_target")
            return false
        }
        let currentDepth = followUpDepthByTargetID[target.id] ?? 0
        guard currentDepth < target.maxFollowUps else {
            logFollowUpDecision(target: target, answerProfile: nil,
                remainingSlots: remainingSlots,
                decision: false, reason: "target_follow_up_budget_spent")
            return false
        }
        let topicUsage = questionUsageByTopicGroup[target.topicGroup] ?? 0
        guard topicUsage < Self.maxQuestionsPerAnchor, !exhaustedAnchors.contains(target.topicGroup) else {
            logFollowUpDecision(target: target, answerProfile: nil,
                remainingSlots: remainingSlots,
                decision: false, reason: "anchor_exhausted")
            return false
        }
        // Breadth pressure: move on if there is no slack for a follow-up.
        let breadthPressure = remainingSlots <= remainingRequiredTargets(after: target) + 1
        guard !breadthPressure else {
            logFollowUpDecision(target: target, answerProfile: nil,
                remainingSlots: remainingSlots,
                decision: false, reason: "breadth_pressure_move_on")
            return false
        }

        // Default is MOVE_ON regardless of anchor source, answer length, word choice,
        // or presence of "I/my/me". The only exception: the answer genuinely did not
        // address the question asked. Brevity, missing pronouns, and interesting depth
        // are never follow-up triggers.
        let profile = AnswerSignalProfile(answer)

        guard relevance == .partiallyRelevant && currentDepth == 0 else {
            logFollowUpDecision(target: target, answerProfile: profile,
                remainingSlots: remainingSlots,
                decision: false, reason: "sufficient_or_usable_answer_move_on")
            return false
        }

        // Partial answer: candidate's response did not address the question asked.
        logFollowUpDecision(target: target, answerProfile: profile,
            remainingSlots: remainingSlots,
            decision: true, reason: "partial_answer_needs_refocus")
        return true
    }

    private func remainingRequiredTargets(after target: InterviewCoverageTarget) -> Int {
        let remaining = plan.targets.filter {
            !coveredTargetIDs.contains($0.id)
                && $0.id != target.id
                && $0.dimension != .adaptiveFollowUp
                && !exhaustedAnchors.contains($0.topicGroup)
        }
        return min(remaining.count, max(0, plan.context.questionCount - completedSubstantiveQuestions - 1))
    }

    private func markCovered(_ target: InterviewCoverageTarget) {
        coveredTargetIDs.insert(target.id)
    }

    private func nextUncoveredTarget(after target: InterviewCoverageTarget) -> InterviewCoverageTarget? {
        guard let start = plan.targets.firstIndex(of: target) else {
            return plan.targets.first { isSelectable($0) }
        }

        for offset in 1...plan.targets.count {
            let index = (start + offset) % plan.targets.count
            let candidate = plan.targets[index]
            if isSelectable(candidate) {
                return candidate
            }
        }
        return plan.targets.first {
            !coveredTargetIDs.contains($0.id)
                && $0.id != target.id
                && $0.dimension != .adaptiveFollowUp
                && !exhaustedAnchors.contains($0.topicGroup)
        }
    }

    private func isSelectable(_ target: InterviewCoverageTarget) -> Bool {
        guard !coveredTargetIDs.contains(target.id) else { return false }
        guard target.dimension != .adaptiveFollowUp else { return false }
        guard !exhaustedAnchors.contains(target.topicGroup) else { return false }
        if recentQuestionAnchors.count == 2,
           recentQuestionAnchors.allSatisfy({ $0 == target.topicGroup }) {
            return false
        }
        return true
    }

    private func questionInstruction(
        prefix: String,
        target: InterviewCoverageTarget,
        language: String,
        acknowledgmentMode: InterviewAcknowledgmentMode,
        extra: String,
        forbiddenEvidenceGroup: String? = nil,
        forbiddenCandidateTopic: String? = nil
    ) -> String {
        let covered = coveredTargetsLine
        let remaining = remainingTargetsLine(current: target)
        let anchorLine = target.anchor.map { "Source anchor: \($0.promptLine)" } ?? "Source anchor: none"
        let questionTargetLine = """
        QuestionTarget:
        - dimension: \(target.dimension.rawValue)
        - anchor: \(target.anchor?.title ?? "none")
        - competency: \(competency(for: target))
        - allowFollowUp: \(target.maxFollowUps > 0)
        - forbiddenAnchors: \(Array(exhaustedAnchors).joined(separator: ", ").orchestrationNilIfBlank ?? "none")
        """
        let forbiddenLine = forbiddenEvidenceGroup.map {
            "FORBIDDEN PREVIOUS TOPIC: Do not reference, name, or continue probing the previous evidence source (\($0)). This question is about the new target dimension only."
        } ?? ""
        // When the candidate introduced a specific CV project/experience in their last answer
        // but the new target did NOT select that anchor, forbid it explicitly by name so
        // the model does not re-frame the next question around it.
        let candidateTopicLine = forbiddenCandidateTopic.map {
            "CANDIDATE TOPIC GUARD: The candidate mentioned '\($0)' in their most recent answer. That was not the selected evidence for this new question. Do NOT ask about '\($0)' — ask about the new target only."
        } ?? ""
        let guards = [forbiddenLine, candidateTopicLine].filter { !$0.isEmpty }.joined(separator: "\n")
        return """
        INTERNAL PLANNING NOTE (never say this to the candidate): the following is Swift orchestration context, not dialogue. Do not read it aloud.
        \(languageLockInstruction(for: language))
        \(prefix) in \(language).
        Current coverage target: \(target.dimension.rawValue).
        Intent: \(target.intent).
        \(questionTargetLine)
        \(anchorLine)
        Covered so far: \(covered).
        Remaining priority: \(remaining).
        Substantive counted questions completed by Swift: \(completedSubstantiveQuestions) of \(plan.context.questionCount).
        Follow-up depth on this target: \(followUpDepthByTargetID[target.id] ?? 0) of \(target.maxFollowUps).
        \(contextLines(for: target))
        \(guards.isEmpty ? "" : guards + "\n")\(acknowledgmentInstruction(for: acknowledgmentMode))
        \(extra)
        The app decides this target; phrase the question naturally and do not expose the plan.
        """
    }

    private func languageLockInstruction(for language: String) -> String {
        "LANGUAGE LOCK: Output only in \(language). Do not mirror, infer, or switch languages because the candidate used, mentioned, or was transcribed as another language. Only Swift can change this language after an explicit candidate request."
    }

    private func closingOpportunityText(for language: String) -> String {
        language == "Arabic"
            ? "\"قبل أن ننهي، هل هناك أي شيء تود أن تسأل عنه أو تضيفه؟\""
            : "\"Before we wrap up, is there anything you'd like to ask or add?\""
    }

    private func finalCloseText(for language: String) -> String {
        language == "Arabic"
            ? "\"شكرا لك. بهذا تنتهي مقابلتنا.\""
            : "\"Thank you. That concludes our interview.\""
    }

    private func acknowledgmentInstruction(for mode: InterviewAcknowledgmentMode) -> String {
        let praiseBan = "Never give live performance praise such as \"great answer\", \"great start\", \"excellent\", \"strong answer\", \"impressive\", or \"you handled that well\". Do not start with coaching-style paraphrases such as \"That makes sense\", \"So it sounds like\", \"I see, so\", or \"Understood, so\"."
        switch mode {
        case .none:
            return "Acknowledgment mode: NONE. Do not begin with an acknowledgment, praise, evaluation, or commentary. Ask the question directly. \(praiseBan)"
        case .neutral:
            return "Acknowledgment mode: NEUTRAL. If a reaction is needed, use at most one short neutral phrase such as \"I see,\" \"Got it,\" or \"Understood,\" then ask the question. Do not praise. \(praiseBan)"
        case .contextual:
            return "Acknowledgment mode: CONTEXTUAL. Put one concrete candidate detail inside the question only if it directly frames the follow-up; otherwise ask directly. Do not add a separate summary, interpretation, or generic commentary. \(praiseBan)"
        }
    }

    /// Returns context lines tailored to the current target so the model knows
    /// exactly which evidence source is selected — and which it must NOT inherit
    /// from its conversation history.
    private func contextLines(for target: InterviewCoverageTarget) -> String {
        var lines = ["Job title: \(plan.context.jobTitle)"]
        if let company = plan.context.company { lines.append("Company: \(company)") }
        if let level = plan.context.candidateLevel { lines.append("Candidate level signal: \(level)") }
        if plan.context.hasCV {
            if target.anchor?.source == .cv {
                lines.append("CV anchor selected for this question: \(target.anchor!.title). Ask about this specific CV evidence; do not switch to a different CV item or reuse a previously discussed project. ANCHOR REQUIREMENT: Your question MUST explicitly name or directly reference \"\(target.anchor!.title)\" — this is validated automatically and will be regenerated if the anchor is absent.")
            } else {
                lines.append("CV evidence pool available but NOT selected for this question. The current target is \(target.dimension.rawValue). Do not name, reference, or continue probing any CV project or experience — including ones mentioned in previous answers.")
            }
        }
        if plan.context.hasJD {
            if target.anchor?.source == .jobDescription {
                lines.append("JD anchor selected for this question: \(target.anchor!.title). Ask about this specific JD requirement. ANCHOR REQUIREMENT: Your question MUST explicitly name or directly reference \"\(target.anchor!.title)\" — this is validated automatically and will be regenerated if the anchor is absent.")
            } else {
                lines.append("JD requirements available but not selected for this question.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var coveredTargetsLine: String {
        let covered = plan.targets.filter { coveredTargetIDs.contains($0.id) }.map { $0.dimension.rawValue }
        return covered.isEmpty ? "none" : covered.joined(separator: ", ")
    }

    private func remainingTargetsLine(current: InterviewCoverageTarget) -> String {
        let remaining = plan.targets
            .filter { !coveredTargetIDs.contains($0.id) && $0.id != current.id }
            .prefix(5)
            .map { $0.debugLabel }
        return remaining.isEmpty ? "none" : remaining.joined(separator: " | ")
    }

    private func logPlan() {
        #if DEBUG
        let openingFamily = OpeningDiversityMemory.familyKey(for: plan.openingTarget)
        print("[InterviewAgenda] budget=\(plan.context.questionCount) openingFamily=\(openingFamily) cv=\(plan.context.hasCV) jd=\(plan.context.hasJD) company=\(plan.context.company != nil) level=\(plan.context.candidateLevel ?? "unknown") openingCandidates=\(plan.openingCandidateCount) cvAnchorCount=\(plan.context.cvAnchors.count) jdAnchorCount=\(plan.context.jdAnchors.count) pattern=\(plan.blueprintPatternKey)")
        for (index, target) in plan.targets.enumerated() {
            let sourceLabel = target.anchor?.source.rawValue ?? "none"
            let parentID = target.anchor.map { CVAnchorSelector.groupKey(for: $0) } ?? "none"
            print("[InterviewAgenda] index=\(index + 1) dimension=\(target.dimension.rawValue) selectedSource=\(sourceLabel) parentEvidenceID=\(parentID) followUpAllowed=\(target.maxFollowUps > 0) maxFollowUps=\(target.maxFollowUps)")
        }
        #endif
    }

    private func logCurrent(action: String, target: InterviewCoverageTarget, relevance: AnswerRelevance?) {
        #if DEBUG
        let relevanceText = relevance?.rawValue ?? "n/a"
        let remainingBudget = max(0, plan.context.questionCount - completedSubstantiveQuestions)
        let nextDim = (action == "follow_up") ? target.dimension.rawValue : (nextUncoveredTarget(after: target)?.dimension.rawValue ?? "closing")
        let nextSrc = (action == "follow_up") ? target.topicGroup : (nextUncoveredTarget(after: target)?.topicGroup ?? "none")
        let answerUsable = relevance.map { $0.containsInterviewEvidence } ?? true
        let criticalClarificationNeeded = (action == "follow_up")
        print("[InterviewDecision] currentDimension=\(target.dimension.rawValue) currentSource=\(target.topicGroup) answerUsable=\(answerUsable) criticalClarificationNeeded=\(criticalClarificationNeeded) followUpDecision=\(action) consecutiveFollowUps=\(consecutiveFollowUpCount) candidateIntroducedTopic=\(lastCandidateIntroducedCVTopic ?? "none") remainingBudget=\(remainingBudget) nextDimension=\(nextDim) nextSource=\(nextSrc) relevance=\(relevanceText)")
        if action == "closing_opportunity" || action == "final_close" {
            print("[InterviewClosing] countedQuestions=\(completedSubstantiveQuestions) budget=\(plan.context.questionCount) stateBefore=\(action == "final_close" ? "closingOpportunity" : "interviewing") action=\(action) stateAfter=\(action == "final_close" ? "completed" : "closingOpportunity")")
        }
        #endif
    }

    private func logFollowUpDecision(
        target: InterviewCoverageTarget,
        answerProfile: AnswerSignalProfile?,
        remainingSlots: Int,
        decision: Bool,
        reason: String
    ) {
        #if DEBUG
        let profileText: String
        if let answerProfile {
            profileText = "words=\(answerProfile.wordCount),specific=\(answerProfile.hasSpecificExample),own=\(answerProfile.hasOwnContribution),decision=\(answerProfile.hasDecisionOrTradeoff),outcome=\(answerProfile.hasOutcome)"
        } else {
            profileText = "profile=not_evaluated"
        }
        let uncoveredPriorityCount = plan.targets.filter { !coveredTargetIDs.contains($0.id) && $0.id != target.id }.count
        print("[FollowUpDecision] currentCompetency=\(target.dimension.rawValue) currentEvidence=\(target.topicGroup) evidenceCollected=\(coveredTargetIDs.contains(target.id)) \(profileText) remainingBudget=\(remainingSlots) uncoveredPriorityCount=\(uncoveredPriorityCount) decision=\(decision ? "FOLLOW_UP" : "MOVE_ON") reason=\(reason)")
        #endif
    }

    private func logTransition(previousTopicGroup: String?, newTarget: InterviewCoverageTarget, transitionType: String) {
        #if DEBUG
        let prevGroup = previousTopicGroup ?? "none"
        let newGroup = newTarget.topicGroup
        let topicChanged = previousTopicGroup != nil && previousTopicGroup != newGroup
        let prevSaturated = previousTopicGroup.map { (questionUsageByTopicGroup[$0] ?? 0) >= 2 } ?? false
        print("[InterviewTransition] previousEvidenceSource=\(prevGroup) newDimension=\(newTarget.dimension.rawValue) newEvidenceSource=\(newGroup) transitionType=\(transitionType) topicChanged=\(topicChanged) previousEvidenceSaturated=\(prevSaturated)")
        #endif
    }

    private func logQuestionGeneration(target: InterviewCoverageTarget, isFollowUp: Bool, topicChanged: Bool) {
        #if DEBUG
        let prevEvidence = previousTopicGroup ?? "none"
        let forbidden = (!isFollowUp && topicChanged) ? prevEvidence : "n/a"
        let mustBeStandalone = !isFollowUp
        print("[QuestionContract] isFollowUp=\(isFollowUp) mustBeStandalone=\(mustBeStandalone) dimension=\(target.dimension.rawValue) source=\(target.topicGroup) forbiddenPreviousSource=\(forbidden) candidateIntroducedTopic=\(lastCandidateIntroducedCVTopic ?? "none") mustChangeTopic=\(topicChanged) consecutiveFollowUps=\(consecutiveFollowUpCount)")
        #endif
    }

    private func logQuestionRuntime(
        target: InterviewCoverageTarget,
        questionTarget: QuestionTarget,
        attempt: Int,
        generatedQuestion: String,
        validation: GeneratedQuestionValidation,
        finalAcceptedQuestion: String?
    ) {
        #if DEBUG
        let previous = previousAnchor ?? "none"
        let previousCount = previousAnchor.map { questionsPerAnchor[$0] ?? 0 } ?? 0
        let covered = plan.targets
            .filter { coveredTargetIDs.contains($0.id) }
            .map { $0.dimension.rawValue }
            .joined(separator: ", ")
        print("""
        [InterviewOrchestrator]
        questionNumber=\(completedSubstantiveQuestions + 1)
        selectedDimension=\(questionTarget.dimension.rawValue)
        selectedAnchor=\(questionTarget.anchorTitle)
        previousAnchor=\(previous)
        questionsForPreviousAnchor=\(previousCount)
        consecutiveFollowUps=\(consecutiveFollowUpCount)
        exhaustedAnchors=\(Array(exhaustedAnchors).sorted().joined(separator: ", "))
        coveredDimensions=\(covered.isEmpty ? "none" : covered)
        generationAttempt=\(attempt)
        generatedQuestion=\(generatedQuestion)
        validationResult=\(validation.isValid ? "ACCEPTED" : "REJECTED")
        rejectionReason=\(validation.isValid ? "none" : validation.reason)
        finalAcceptedQuestion=\(finalAcceptedQuestion ?? "none")
        targetID=\(target.id.uuidString)
        """)
        #endif
    }

    private func logOpeningQuestionIfNeeded(
        action: InterviewNextAction,
        questionTarget: QuestionTarget,
        generatedQuestion: String,
        validation: GeneratedQuestionValidation
    ) {
        #if DEBUG
        guard action.isFirstQuestion else { return }
        let containsPreviousContextLanguage = GeneratedQuestionValidator.containsPreviousContextLanguage(generatedQuestion)
        print("""
        [OpeningQuestion]
        selectedDimension=\(questionTarget.dimension.rawValue)
        selectedAnchor=\(questionTarget.anchorTitle)
        generatedQuestion=\(generatedQuestion)
        containsPreviousContextLanguage=\(containsPreviousContextLanguage)
        validationResult=\(validation.isValid ? "ACCEPTED" : "REJECTED")
        """)
        #endif
    }

    /// Scans the candidate's answer for CV anchor titles (projects, experiences,
    /// achievements). Returns the first matched anchor title, or nil.
    /// Only matches primary evidence kinds to avoid false positives on skill
    /// keywords or technologies that are common nouns.
    private func extractCandidateIntroducedCVTopic(from answer: String) -> String? {
        guard plan.context.hasCV else { return nil }
        let lowercased = answer.lowercased()
        let primaryKinds: Set<InterviewAnchor.Kind> = [.project, .experience, .achievement, .responsibility]
        for anchor in plan.context.cvAnchors where primaryKinds.contains(anchor.kind) {
            let titleTokens = anchor.title.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .filter { $0.count >= 4 }
                .map(String.init)
            guard !titleTokens.isEmpty else { continue }
            // Require at least 2 matching tokens for multi-word titles, 1 for single-word.
            let threshold = min(titleTokens.count, 2)
            let matchCount = titleTokens.filter { lowercased.contains($0) }.count
            if matchCount >= threshold {
                return anchor.title
            }
        }
        return nil
    }
}

private struct AnswerSignalProfile {
    let wordCount: Int
    let hasSpecificExample: Bool
    let hasOwnContribution: Bool
    let hasDecisionOrTradeoff: Bool
    let hasOutcome: Bool
    let asksQuestion: Bool
    let hasProfessionalContext: Bool

    init(_ answer: String) {
        let lowercased = answer.lowercased()
        let words = lowercased.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        wordCount = words.count
        asksQuestion = lowercased.contains("?")
        hasSpecificExample = Self.containsAny(lowercased, [
            "for example", "in my project", "on my project", "when i", "i worked on",
            "we built", "i built", "i developed", "i implemented", "i designed",
            "i led", "i managed", "i tested", "i validated", "i measured"
        ])
        hasOwnContribution = Self.containsAny(lowercased, [
            "i ", "my ", "me ", "i'm", "im ", "i've", "ive ", "i was responsible",
            "i led", "i owned", "i handled", "i built", "i decided"
        ])
        hasDecisionOrTradeoff = Self.containsAny(lowercased, [
            "decided", "decision", "trade-off", "tradeoff", "because", "reason",
            "chose", "instead", "balanced", "constraint", "limited"
        ])
        hasOutcome = Self.containsAny(lowercased, [
            "result", "impact", "improved", "reduced", "increased", "measured",
            "users", "customers", "validated", "evaluated", "solved", "worked"
        ])
        hasProfessionalContext = Self.containsAny(lowercased, [
            "project", "role", "team", "work", "job", "experience", "skill",
            "built", "created", "developed", "designed", "managed", "led",
            "challenge", "result", "impact", "customer", "user", "data",
            "testing", "technical", "communication", "collaboration",
            "responsibility", "company", "research", "model", "system"
        ])
    }

    var isBrief: Bool {
        wordCount < 14
    }

    private static func containsAny(_ text: String, _ signals: [String]) -> Bool {
        signals.contains { text.contains($0) }
    }
}

struct GeneratedQuestionValidation: Sendable, Equatable {
    let isValid: Bool
    let reason: String

    static let valid = GeneratedQuestionValidation(isValid: true, reason: "accepted")
}

enum GeneratedQuestionValidator {
    static func validate(
        question: String,
        target: QuestionTarget,
        previousAnchor: String?,
        previousQuestions: [String],
        exhaustedAnchors: Set<String>,
        knownCVAnchors: [InterviewAnchor],
        isFollowUp: Bool,
        isFirstQuestion: Bool
    ) -> GeneratedQuestionValidation {
        let normalizedQuestion = normalized(question)
        let lowercasedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowercasedQuestion.contains("?") || normalizedQuestion.hasPrefix("tell me") || normalizedQuestion.hasPrefix("describe") else {
            return .init(isValid: false, reason: "not_a_question")
        }

        if isFirstQuestion, containsPreviousContextLanguage(normalizedQuestion) {
            return .init(isValid: false, reason: "first_question_implies_previous_context")
        }

        if containsMetaPlanningLanguage(normalizedQuestion) {
            return .init(isValid: false, reason: "meta_planning_language")
        }

        if let duplicate = previousQuestions.first(where: { similarity(normalizedQuestion, normalized($0)) >= 0.72 }) {
            return .init(isValid: false, reason: "duplicates_previous_question:\(String(duplicate.prefix(80)))")
        }

        for forbidden in exhaustedAnchors.union(Set(target.forbiddenAnchors)) {
            if mentions(anchorKey: forbidden, in: normalizedQuestion, knownCVAnchors: knownCVAnchors) {
                return .init(isValid: false, reason: "references_forbidden_or_exhausted_anchor:\(forbidden)")
            }
        }

        if !isFollowUp,
           let previousAnchor,
           previousAnchor != target.anchorKey,
           mentions(anchorKey: previousAnchor, in: normalizedQuestion, knownCVAnchors: knownCVAnchors) {
            return .init(isValid: false, reason: "continues_previous_anchor_when_new_topic_required:\(previousAnchor)")
        }

        if let anchor = target.anchor {
            if anchor.source == .cv || anchor.source == .jobDescription || anchor.source == .company {
                guard mentions(anchor: anchor, in: normalizedQuestion) else {
                    return .init(isValid: false, reason: "missing_required_anchor:\(anchor.title)")
                }
            }
        } else if target.dimension != .cvExperience {
            if let cvAnchor = knownCVAnchors.first(where: { mentions(anchor: $0, in: normalizedQuestion) }) {
                return .init(isValid: false, reason: "unselected_cv_anchor_used:\(cvAnchor.title)")
            }
        }

        guard matchesDimension(target.dimension, question: normalizedQuestion) else {
            return .init(isValid: false, reason: "dimension_mismatch:\(target.dimension.rawValue)")
        }

        return .valid
    }

    /// Fast partial check used for early audio release. Only validates the two signals
    /// that are reliable on a partial sentence: anchor mention and dimension keywords.
    /// Duplicate, forbidden-anchor, and continuation checks require the full text.
    static func partiallyValidate(
        partialQuestion: String,
        target: QuestionTarget,
        exhaustedAnchors: Set<String>,
        knownCVAnchors: [InterviewAnchor]
    ) -> Bool {
        let normalizedQuestion = normalized(partialQuestion)
        guard !containsMetaPlanningLanguage(normalizedQuestion) else { return false }
        if let anchor = target.anchor {
            if anchor.source == .cv || anchor.source == .jobDescription || anchor.source == .company {
                guard mentions(anchor: anchor, in: normalizedQuestion) else { return false }
            }
        }
        return matchesDimension(target.dimension, question: normalizedQuestion)
    }

    static func containsPreviousContextLanguage(_ question: String) -> Bool {
        let normalizedQuestion = normalized(question)
        return containsAny(normalizedQuestion, previousContextPhrases)
    }

    static func containsMetaPlanningLanguage(_ question: String) -> Bool {
        let normalizedQuestion = normalized(question)
        return containsAny(normalizedQuestion, metaPlanningPhrases)
    }

    private static func matchesDimension(_ dimension: InterviewCoverageDimension, question: String) -> Bool {
        switch dimension {
        case .cvExperience:
            return containsAny(question, ["project", "experience", "built", "developed", "implemented", "implementation", "contribution", "impact", "worked", "created", "led", "owned", "result"])
        case .roleSpecific:
            return containsAny(question, ["role", "responsibility", "ready", "skill", "prepared", "work as", "position"])
        case .behavioral:
            return containsAny(question, ["time", "example", "situation", "challenge", "problem", "decision", "handled", "tell me about"])
        case .technical:
            return containsAny(question, ["technical", "trade", "system", "model", "data", "design", "evaluate", "implementation", "approach"])
        case .jdRequirement:
            return containsAny(question, ["require", "responsibility", "calls for", "experience", "capability", "role involves", "prepared"])
        case .collaboration:
            return containsAny(question, ["team", "collaborat", "communication", "stakeholder", "worked with", "shared"])
        case .motivation:
            return containsAny(question, ["motivat", "interested", "why", "drawn", "company", "opportunity"])
        case .ownership:
            return containsAny(question, ["own", "responsib", "accountab", "decision", "led", "took"])
        case .adaptability:
            return containsAny(question, ["learn", "adapt", "change", "adjust", "new", "pressure"])
        case .contextualOpening:
            return containsAny(question, ["background", "experience", "prepared", "relevant", "led you", "walk me"])
        case .adaptiveFollowUp:
            return true
        case .closingSubstantive:
            return containsAny(question, ["strength", "bring", "discussed", "role", "add", "important"])
        }
    }

    private static func mentions(anchor: InterviewAnchor, in question: String) -> Bool {
        let titleTokens = meaningfulTokens(anchor.title)
        let keywordTokens = anchor.keywords.flatMap { meaningfulTokens($0) }
        let detailTokens = meaningfulTokens(anchor.detail).prefix(8)
        let candidates = Array(titleTokens + keywordTokens + detailTokens)
        // If the anchor title has no meaningful tokens (all short or stop-words), we cannot
        // validate presence — return true so the question is never rejected for this anchor.
        // Returning false here would cause every response for such anchors to fail validation
        // and permanently fall back to the deterministic template, adding unnecessary latency.
        guard !candidates.isEmpty else { return true }
        let threshold = titleTokens.count >= 2 ? 2 : 1
        let titleMatches = titleTokens.filter { question.contains($0) }.count
        if titleMatches >= threshold { return true }
        return candidates.filter { question.contains($0) }.count >= min(3, max(1, candidates.count))
    }

    private static func mentions(anchorKey: String, in question: String, knownCVAnchors: [InterviewAnchor]) -> Bool {
        knownCVAnchors
            .filter { CVAnchorSelector.groupKey(for: $0) == anchorKey }
            .contains { mentions(anchor: $0, in: question) }
    }

    private static func meaningfulTokens(_ text: String) -> [String] {
        normalized(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains { text.contains($0) }
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.split(separator: " ").map(String.init).filter { $0.count > 3 })
        let right = Set(rhs.split(separator: " ").map(String.init).filter { $0.count > 3 })
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let overlap = left.intersection(right).count
        return Double(overlap) / Double(min(left.count, right.count))
    }

    private static let stopWords: Set<String> = [
        "about", "your", "with", "that", "this", "from", "what", "when", "where", "which",
        "could", "would", "tell", "describe", "role", "work", "project", "experience"
    ]

    private static let previousContextPhrases: [String] = [
        "that s great to hear",
        "thats great to hear",
        "great to hear",
        "good to hear",
        "glad to hear",
        "thank you for sharing",
        "thanks for sharing",
        "thank you for that",
        "thanks for that",
        "based on what you said",
        "based on what you shared",
        "based on your answer",
        "you mentioned",
        "as you mentioned",
        "from what you shared",
        "from what you said",
        "what you shared",
        "what you said",
        "let s move on",
        "lets move on",
        "moving on",
        "move on to",
        "next question",
        "let s dig deeper",
        "lets dig deeper",
        "dig a bit deeper",
        "dig deeper",
        "following up",
        "follow up on",
        "earlier you said",
        "you ve described",
        "you have described",
        "you described",
        "that example",
        "that experience",
        "tell me more about that",
        "can you expand on that",
        "could you expand on that",
        "you touched on",
        "you brought up",
        "as we discussed",
        "we discussed",
        "as discussed",
        // Arabic equivalents — forbidden on the first question the same as English
        "شكرا لمشاركتك",
        "شكرا لتوضيحك",
        "شكرا على مشاركتك",
        "كما ذكرت",
        "كما اشرت",
        "بناء على ما قلته",
        "بناء على ما ذكرته",
        "بناء على ما شاركته",
        "بالعودة الى ما ذكرته",
        "ذكرت سابقا",
        "اشرت الى",
        "لقد ذكرت"
    ]

    private static let metaPlanningPhrases: [String] = [
        "if the user",
        "based on the user",
        "based on the user s",
        "user provides",
        "user has provided",
        "user s response",
        "user s answer",
        "the assistant",
        "the interviewer should",
        "interviewer should",
        "i should ask",
        "i need more information",
        "need more information",
        "i will follow up",
        "i ll follow up",
        "i can follow up",
        "i would follow up",
        "i will be able to",
        "i ll be able to",
        "will be able to follow up",
        "next i will",
        "i will ask next",
        "i plan to",
        "my plan",
        "my strategy",
        "my reasoning",
        "internal reasoning",
        "prompt instruction",
        "system instruction"
    ]
}

private enum InterviewBlueprintSlot: String, CaseIterable {
    case opening
    case background
    case roleSpecific
    case motivation
    case primaryCV
    case secondaryCV
    case tertiaryCV
    case primaryJD
    case secondaryJD
    case behavioral
    case collaboration
    case technical
    case adaptive
    case closing
}

@MainActor
enum InterviewPlanner {
    private struct BlueprintResult {
        let targets: [InterviewCoverageTarget]
        let patternKey: String
    }

    private struct BlueprintPool {
        let opening: InterviewCoverageTarget
        let background: InterviewCoverageTarget
        let role: InterviewCoverageTarget
        let motivation: InterviewCoverageTarget
        let behavioral: InterviewCoverageTarget
        let collaboration: InterviewCoverageTarget
        let technical: InterviewCoverageTarget
        let adaptive: InterviewCoverageTarget
        let closing: InterviewCoverageTarget
        let cvTargets: [InterviewCoverageTarget]
        let jdTargets: [InterviewCoverageTarget]

        func target(for slot: InterviewBlueprintSlot) -> InterviewCoverageTarget? {
            switch slot {
            case .opening:
                return opening
            case .background:
                return background
            case .roleSpecific:
                return role
            case .motivation:
                return motivation
            case .primaryCV:
                return cvTargets.first
            case .secondaryCV:
                return cvTargets.dropFirst().first
            case .tertiaryCV:
                return cvTargets.dropFirst(2).first
            case .primaryJD:
                return jdTargets.first
            case .secondaryJD:
                return jdTargets.dropFirst().first
            case .behavioral:
                return behavioral
            case .collaboration:
                return collaboration
            case .technical:
                return technical
            case .adaptive:
                return adaptive
            case .closing:
                return closing
            }
        }
    }

    static func makePlan(context: InterviewContext) -> InterviewPlan {
        let maxFollowUps = context.questionCount >= 15 ? 2 : 1

        let openingCandidates = openingTargets(context: context, maxFollowUps: maxFollowUps)
        let opening = OpeningDiversityMemory.chooseOpening(
            from: openingCandidates,
            fallback: roleTarget(context: context, maxFollowUps: maxFollowUps)
        )
        let blueprint = balancedTargets(context: context, opening: opening, maxFollowUps: maxFollowUps)
        var capped = capTargetsPreservingClosing(blueprint.targets, limit: max(context.questionCount, 1))
        // Invariant: a plan built from a CV must always include at least one CV-grounded
        // target. This guards against the edge case where pattern rotation and opening
        // deduplication together produce a plan with zero CV questions even when the
        // candidate supplied a valid CV.
        capped = ensureCVCoverage(capped, context: context, maxFollowUps: maxFollowUps)
        return InterviewPlan(
            context: context,
            targets: capped.isEmpty ? [opening] : capped,
            openingTargetID: opening.id,
            openingCandidateCount: openingCandidates.count,
            blueprintPatternKey: blueprint.patternKey
        )
    }

    /// Safety-net invariant. If a CV exists but the assembled plan has no CV-anchored
    /// target, replace the weakest generic slot with one CV-grounded target.
    /// This fires only in edge cases; the patterns themselves are the primary guarantee.
    private static func ensureCVCoverage(
        _ targets: [InterviewCoverageTarget],
        context: InterviewContext,
        maxFollowUps: Int
    ) -> [InterviewCoverageTarget] {
        guard context.hasCV else { return targets }
        guard !targets.contains(where: { $0.anchor?.source == .cv }) else { return targets }
        guard targets.count >= 2 else { return targets }

        let anchors = CVAnchorSelector.select(from: context.cvAnchors, limit: 1, excluding: nil)
        guard let anchor = anchors.first else { return targets }

        let cvTarget = InterviewCoverageTarget(
            dimension: .cvExperience,
            intent: "probe the candidate's actual contribution, decisions, and impact for this CV anchor",
            anchor: anchor,
            maxFollowUps: min(maxFollowUps, 2)
        )

        // Replace the last occurrence of a generic (role- or adaptive-anchored, or nil-anchored)
        // target from this priority list — least essential to most.
        let replacementPriority: [InterviewCoverageDimension] = [
            .adaptiveFollowUp, .adaptability, .ownership, .collaboration, .behavioral, .technical
        ]
        var result = targets
        for dim in replacementPriority {
            if let idx = result.indices.reversed().first(where: { i in
                let t = result[i]
                return t.dimension == dim
                    && t.dimension != .closingSubstantive
                    && (t.anchor == nil || t.anchor?.source == .role || t.anchor?.source == .adaptive)
            }) {
                let replacedDim = result[idx].dimension.rawValue
                result[idx] = cvTarget
                #if DEBUG
                print("[CVInvariant] enforced cv_coverage: replaced=\(replacedDim) with cv anchor=\(anchor.title)")
                #endif
                return result
            }
        }

        // Last resort: replace the slot immediately before closing.
        let closingIdx = result.lastIndex(where: { $0.dimension == .closingSubstantive })
        let insertIdx = closingIdx.map { max($0 - 1, 0) } ?? max(result.count - 2, 0)
        if insertIdx < result.count {
            let replacedDim = result[insertIdx].dimension.rawValue
            result[insertIdx] = cvTarget
            #if DEBUG
            print("[CVInvariant] enforced cv_coverage: replaced position=\(insertIdx) (\(replacedDim)) with cv anchor=\(anchor.title)")
            #endif
        }
        return result
    }

    private static func balancedTargets(
        context: InterviewContext,
        opening: InterviewCoverageTarget,
        maxFollowUps: Int
    ) -> BlueprintResult {
        let cvTargets = requiredCVTargets(
            context: context,
            maxFollowUps: maxFollowUps,
            excludingOpeningAnchor: opening.anchor?.source == .cv ? opening.anchor : nil
        )
        let jdTargets = requiredJDTargets(context: context, maxFollowUps: maxFollowUps)
        let motivation = motivationTarget(context: context)
        let background = backgroundTarget(context: context, maxFollowUps: maxFollowUps)
        let role = roleTarget(context: context, maxFollowUps: maxFollowUps)
        let behavioral = InterviewCoverageTarget(
            dimension: .behavioral,
            intent: "evaluate a role-relevant example of problem solving, ownership, or judgment",
            anchor: nil,
            maxFollowUps: maxFollowUps
        )
        let collaboration = InterviewCoverageTarget(
            dimension: .collaboration,
            intent: "evaluate teamwork, communication, stakeholder handling, or collaboration",
            anchor: nil,
            maxFollowUps: maxFollowUps
        )
        let technical = InterviewCoverageTarget(
            dimension: .technical,
            intent: "probe practical domain knowledge, trade-offs, and decision quality for the role",
            anchor: nil,
            maxFollowUps: maxFollowUps
        )
        let adaptive = InterviewCoverageTarget(
            dimension: .adaptiveFollowUp,
            intent: "reserved only for an explicitly scheduled clarification of the immediately previous answer",
            anchor: InterviewAnchor(source: .adaptive, kind: .unknown, title: "immediate previous answer", detail: "Use only the immediately previous candidate answer when Swift schedules a follow-up.", keywords: []),
            maxFollowUps: 1
        )
        let closing = InterviewCoverageTarget(
            dimension: .closingSubstantive,
            intent: "ask a final substantive role-relevant question before the uncounted closing opportunity",
            anchor: nil,
            maxFollowUps: 0
        )

        let pool = BlueprintPool(
            opening: opening,
            background: background,
            role: role,
            motivation: motivation,
            behavioral: behavioral,
            collaboration: collaboration,
            technical: technical,
            adaptive: adaptive,
            closing: closing,
            cvTargets: cvTargets,
            jdTargets: jdTargets
        )

        let selectedPattern = BlueprintVariationMemory.choosePattern(
            from: blueprintPatterns(for: context),
            context: context
        )

        var targets: [InterviewCoverageTarget] = []
        var seen = Set<String>()
        for slot in selectedPattern {
            guard let target = pool.target(for: slot) else { continue }
            appendUnique(target, to: &targets, seen: &seen)
        }

        let fallbackPool = cvTargets
            + jdTargets
            + baselineTargets(context: context, maxFollowUps: maxFollowUps)
            + [background, role, behavioral, collaboration, technical, motivation, closing]
        for target in fallbackPool where targets.count < context.questionCount {
            appendUnique(target, to: &targets, seen: &seen)
        }

        moveClosingTargetToEnd(of: &targets)

        return BlueprintResult(
            targets: targets,
            patternKey: selectedPattern.map(\.rawValue).joined(separator: ">")
        )
    }

    private static func blueprintPatterns(for context: InterviewContext) -> [[InterviewBlueprintSlot]] {
        let hasCompany = context.company?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasJD = context.hasJD

        if context.questionCount <= 5 {
            // Every 5-question pattern includes .primaryCV so that CV evidence is always
            // evaluated when a CV is provided. If no CV exists the slot returns nil and
            // is skipped; the fallback pool then fills the gap with the next-best target.
            return [
                [.opening, .primaryCV, .roleSpecific, hasJD ? .primaryJD : .technical, .closing],
                [.opening, hasCompany ? .motivation : .roleSpecific, .primaryCV, hasJD ? .primaryJD : .behavioral, .closing],
                [.opening, hasJD ? .primaryJD : .technical, .primaryCV, hasCompany ? .motivation : .behavioral, .closing]
            ]
        }

        if context.questionCount <= 10 {
            return [
                [.opening, .background, .primaryCV, .primaryJD, hasCompany ? .motivation : .roleSpecific, .collaboration, .technical, .behavioral, .secondaryCV, .closing],
                [.opening, hasCompany ? .motivation : .roleSpecific, .background, .primaryJD, .technical, .primaryCV, .behavioral, .collaboration, .secondaryCV, .closing],
                [.opening, .technical, .background, .primaryCV, .collaboration, hasJD ? .primaryJD : .roleSpecific, hasCompany ? .motivation : .behavioral, .secondaryCV, .secondaryJD, .closing],
                [.opening, .roleSpecific, .background, .behavioral, .primaryCV, .collaboration, .primaryJD, .technical, hasCompany ? .motivation : .secondaryCV, .closing]
            ]
        }

        return [
            [.opening, .background, .primaryCV, .primaryJD, .behavioral, .collaboration, .technical, .secondaryCV, .motivation, .roleSpecific, .secondaryJD, .tertiaryCV, .closing],
            [.opening, .motivation, .roleSpecific, .primaryJD, .technical, .primaryCV, .collaboration, .behavioral, .secondaryCV, .secondaryJD, .background, .tertiaryCV, .closing],
            [.opening, .technical, .background, .primaryCV, .behavioral, .primaryJD, .collaboration, .secondaryCV, .roleSpecific, .motivation, .secondaryJD, .tertiaryCV, .closing]
        ]
    }

    private static func capTargetsPreservingClosing(_ targets: [InterviewCoverageTarget], limit: Int) -> [InterviewCoverageTarget] {
        guard targets.count > limit else { return targets }
        var capped = Array(targets.prefix(limit))
        guard
            let closing = targets.last(where: { $0.dimension == .closingSubstantive }),
            !capped.contains(where: { $0.id == closing.id }),
            !capped.isEmpty
        else {
            return capped
        }
        capped[capped.count - 1] = closing
        return capped
    }

    private static func moveClosingTargetToEnd(of targets: inout [InterviewCoverageTarget]) {
        guard let index = targets.firstIndex(where: { $0.dimension == .closingSubstantive }) else { return }
        let closing = targets.remove(at: index)
        targets.append(closing)
    }

    private static func appendUnique(
        _ target: InterviewCoverageTarget,
        to targets: inout [InterviewCoverageTarget],
        seen: inout Set<String>
    ) {
        let key = target.deduplicationKey
        guard !seen.contains(key) else { return }
        seen.insert(key)
        targets.append(target)
    }

    private static func openingTargets(context: InterviewContext, maxFollowUps: Int) -> [InterviewCoverageTarget] {
        var targets: [InterviewCoverageTarget] = []
        if let anchor = context.cvAnchors.first {
            targets.append(InterviewCoverageTarget(
                dimension: .cvExperience,
                intent: "open with a specific role-relevant CV anchor, avoiding generic background or challenge phrasing",
                anchor: anchor,
                maxFollowUps: min(maxFollowUps, 2)
            ))
        }
        if let anchor = context.jdAnchors.first {
            targets.append(InterviewCoverageTarget(
                dimension: .jdRequirement,
                intent: "open with a requirement from the job description and ask for evidence from the candidate's experience",
                anchor: anchor,
                maxFollowUps: maxFollowUps
            ))
        }
        if let company = context.company {
            targets.append(InterviewCoverageTarget(
                dimension: .motivation,
                intent: "open on motivation for this role at \(company) without fabricating company facts",
                anchor: InterviewAnchor(source: .company, kind: .roleContext, title: company, detail: "Provided company context only.", keywords: []),
                maxFollowUps: 1
            ))
        }
        targets.append(InterviewCoverageTarget(
            dimension: .contextualOpening,
            intent: "open on the candidate's most relevant recent experience for the \(context.jobTitle) role",
            anchor: InterviewAnchor(source: .role, kind: .roleContext, title: "\(context.jobTitle) background", detail: "Use the target role only; do not ask a generic tell-me-about-yourself question unless it is made role-specific.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        ))
        targets.append(motivationTarget(context: context))
        targets.append(InterviewCoverageTarget(
            dimension: .technical,
            intent: "open on practical role-specific experience or judgment",
            anchor: InterviewAnchor(source: .role, kind: .roleContext, title: "\(context.jobTitle) practical experience", detail: "Ask for evidence relevant to the target role.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        ))
        targets.append(InterviewCoverageTarget(
            dimension: .behavioral,
            intent: "open with a role-relevant ownership or problem-solving example",
            anchor: InterviewAnchor(source: .role, kind: .roleContext, title: "\(context.jobTitle) ownership", detail: "Ask for a concrete professional, academic, or project example relevant to the role.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        ))
        targets.append(InterviewCoverageTarget(
            dimension: .collaboration,
            intent: "open on communication or collaboration expected in the target role",
            anchor: InterviewAnchor(source: .role, kind: .roleContext, title: "\(context.jobTitle) collaboration", detail: "Use general role expectations only.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        ))
        targets.append(roleTarget(context: context, maxFollowUps: maxFollowUps))
        return targets
    }

    private static func requiredCVTargets(
        context: InterviewContext,
        maxFollowUps: Int,
        excludingOpeningAnchor: InterviewAnchor?
    ) -> [InterviewCoverageTarget] {
        guard context.hasCV else { return [] }
        let targetCount = context.questionCount <= 5 ? 1 : (context.questionCount <= 10 ? 2 : 3)
        let anchors = CVAnchorSelector.select(
            from: context.cvAnchors,
            limit: targetCount,
            excluding: excludingOpeningAnchor
        )
        return anchors.map { anchor in
            InterviewCoverageTarget(
                dimension: .cvExperience,
                intent: "probe the candidate's actual contribution, decisions, and impact for this CV anchor",
                anchor: anchor,
                maxFollowUps: min(maxFollowUps, 2)
            )
        }
    }

    private static func requiredJDTargets(context: InterviewContext, maxFollowUps: Int) -> [InterviewCoverageTarget] {
        guard context.hasJD else { return [] }
        let targetCount = context.questionCount <= 5 ? 1 : (context.questionCount <= 10 ? 2 : 3)
        return context.jdAnchors.prefix(targetCount).map { anchor in
            InterviewCoverageTarget(
                dimension: .jdRequirement,
                intent: "evaluate evidence against an important job-description requirement",
                anchor: anchor,
                maxFollowUps: maxFollowUps
            )
        }
    }

    private static func baselineTargets(context: InterviewContext, maxFollowUps: Int) -> [InterviewCoverageTarget] {
        var targets: [InterviewCoverageTarget] = []

        if context.questionCount >= 10 {
            targets.append(InterviewCoverageTarget(
                dimension: .technical,
                intent: "probe practical domain knowledge, trade-offs, and decision quality for the role",
                anchor: nil,
                maxFollowUps: maxFollowUps
            ))
            targets.append(InterviewCoverageTarget(
                dimension: .ownership,
                intent: "evaluate personal ownership, decision-making, and accountability in a relevant situation",
                anchor: nil,
                maxFollowUps: maxFollowUps
            ))
            targets.append(InterviewCoverageTarget(
                dimension: .adaptability,
                intent: "evaluate learning, adaptability, or how the candidate responds when conditions change",
                anchor: nil,
                maxFollowUps: maxFollowUps
            ))
        }

        targets += [
            roleTarget(context: context, maxFollowUps: maxFollowUps),
            InterviewCoverageTarget(
                dimension: .behavioral,
                intent: "evaluate a role-relevant example of problem solving or ownership",
                anchor: nil,
                maxFollowUps: maxFollowUps
            ),
            InterviewCoverageTarget(
                dimension: .collaboration,
                intent: "evaluate communication, teamwork, stakeholder handling, or collaboration",
                anchor: nil,
                maxFollowUps: maxFollowUps
            )
        ]

        targets.append(InterviewCoverageTarget(
            dimension: .closingSubstantive,
            intent: "ask a final substantive role-relevant question before the uncounted closing opportunity",
            anchor: nil,
            maxFollowUps: 0
        ))
        return targets
    }

    private static func roleTarget(context: InterviewContext, maxFollowUps: Int) -> InterviewCoverageTarget {
        InterviewCoverageTarget(
            dimension: .roleSpecific,
            intent: "evaluate readiness for the \(context.jobTitle) role with a concrete example",
            anchor: InterviewAnchor(source: .role, kind: .roleContext, title: context.jobTitle, detail: "Target role from interview setup.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        )
    }

    private static func backgroundTarget(context: InterviewContext, maxFollowUps: Int) -> InterviewCoverageTarget {
        InterviewCoverageTarget(
            dimension: .contextualOpening,
            intent: "understand the candidate's relevant background and role readiness without asking a generic autobiography question",
            anchor: InterviewAnchor(source: .role, kind: .roleContext, title: "\(context.jobTitle) background", detail: "Use the target role only; ask for relevant preparation, experience, or trajectory.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        )
    }

    private static func motivationTarget(context: InterviewContext) -> InterviewCoverageTarget {
        let title = context.company ?? "\(context.jobTitle) motivation"
        let detail = context.company.map { "Provided company context only: \($0). Do not fabricate company facts." } ?? "Role motivation from setup data only."
        return InterviewCoverageTarget(
            dimension: .motivation,
            intent: "evaluate motivation for this role direction and fit with the candidate's background",
            anchor: InterviewAnchor(source: context.company == nil ? .role : .company, kind: .roleContext, title: title, detail: detail, keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: 0
        )
    }
}

private extension InterviewCoverageTarget {
    var deduplicationKey: String {
        guard let anchor else {
            return "dimension:\(dimension.rawValue)"
        }
        if anchor.source == .role || anchor.source == .adaptive {
            return "dimension:\(dimension.rawValue)"
        }
        return [
            dimension.rawValue,
            CVAnchorSelector.groupKey(for: anchor)
        ].joined(separator: "-")
    }

    var topicGroup: String {
        anchor.map { CVAnchorSelector.groupKey(for: $0) } ?? "dimension:\(dimension.rawValue)"
    }
}

enum CVAnchorSelector {
    static func select(
        from anchors: [InterviewAnchor],
        limit: Int,
        excluding openingAnchor: InterviewAnchor?
    ) -> [InterviewAnchor] {
        var selected: [InterviewAnchor] = []
        var selectedGroups = Set<String>()

        if let openingAnchor {
            selectedGroups.insert(groupKey(for: openingAnchor))
            logSelected(anchor: openingAnchor, index: 0, group: groupKey(for: openingAnchor), reason: "opening")
        }

        for pass in SelectionPass.allCases {
            for anchor in anchors where selected.count < limit {
                guard pass.accepts(anchor) else { continue }
                let group = groupKey(for: anchor)
                if selectedGroups.contains(group) {
                    logSkipped(anchor: anchor, group: group)
                    continue
                }
                selected.append(anchor)
                selectedGroups.insert(group)
                logSelected(anchor: anchor, index: selected.count, group: group, reason: pass.rawValue)
            }
        }

        return selected
    }

    static func groupKey(for anchor: InterviewAnchor) -> String {
        let titleTokens = normalizedToken(anchor.title)
            .split(separator: " ")
            .prefix(4)
            .joined(separator: " ")
        let titleGroup = titleTokens.isEmpty ? "untitled" : String(titleTokens)

        switch anchor.source {
        case .cv:
            switch anchor.kind {
            case .project:
                return "project:\(titleGroup)"
            case .experience, .responsibility:
                return "experience:\(titleGroup)"
            case .achievement:
                return "achievement:\(titleGroup)"
            case .skill, .technology:
                return "skill:\(titleGroup)"
            case .jdRequirement, .roleContext, .unknown:
                break
            }
        case .jobDescription:
            return "jd:\(titleGroup)"
        case .company:
            return "company:\(titleGroup)"
        case .role:
            return "role:\(titleGroup)"
        case .adaptive:
            return "adaptive:\(titleGroup)"
        }

        let meaningfulKeywords = anchor.keywords
            .map { normalizedToken($0) }
            .filter { $0.count > 2 }
            .prefix(3)
            .joined(separator: ",")
        let fallback = titleTokens.isEmpty ? meaningfulKeywords : String(titleTokens)
        return "\(anchor.kind.rawValue.lowercased()):\(fallback)"
    }

    private static func normalizedToken(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func logSelected(anchor: InterviewAnchor, index: Int, group: String, reason: String) {
        #if DEBUG
        let label = index == 0 ? "openingAnchor" : "selectedAnchor\(index)"
        print("[CVPlan] \(label)=\(anchor.title) kind=\(anchor.kind.rawValue) source=\(anchor.source.rawValue) group=\(group) reason=\(reason)")
        #endif
    }

    private static func logSkipped(anchor: InterviewAnchor, group: String) {
        #if DEBUG
        print("[CVPlan] skippedAnchor=\(anchor.title) kind=\(anchor.kind.rawValue) source=\(anchor.source.rawValue) group=\(group) reason=duplicate_cv_area")
        #endif
    }

    private enum SelectionPass: String, CaseIterable {
        case primaryEvidence = "primary_evidence"
        case roleSkills = "role_skills"
        case fallback = "fallback"

        func accepts(_ anchor: InterviewAnchor) -> Bool {
            switch self {
            case .primaryEvidence:
                return [.project, .experience, .achievement, .responsibility].contains(anchor.kind)
            case .roleSkills:
                return [.skill, .technology].contains(anchor.kind)
            case .fallback:
                return true
            }
        }
    }
}

@MainActor
private enum OpeningDiversityMemory {
    private static let storageKey = "StepIN.recentOpeningIntentKeys"
    private static let maxRecentCount = 6

    static func familyKey(for target: InterviewCoverageTarget) -> String { key(for: target) }

    static func chooseOpening(
        from candidates: [InterviewCoverageTarget],
        fallback: InterviewCoverageTarget
    ) -> InterviewCoverageTarget {
        let usableCandidates = candidates.isEmpty ? [fallback] : candidates
        let recentOpeningKeys = persistedKeys()
        let preferred = usableCandidates.first { !recentOpeningKeys.contains(key(for: $0)) }
        let selected = preferred ?? usableCandidates.randomElement() ?? fallback
        remember(selected)
        return selected
    }

    private static func remember(_ target: InterviewCoverageTarget) {
        var recentOpeningKeys = persistedKeys()
        recentOpeningKeys.append(key(for: target))
        if recentOpeningKeys.count > maxRecentCount {
            recentOpeningKeys.removeFirst(recentOpeningKeys.count - maxRecentCount)
        }
        UserDefaults.standard.set(recentOpeningKeys, forKey: storageKey)
    }

    private static func persistedKeys() -> [String] {
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }

    private static func key(for target: InterviewCoverageTarget) -> String {
        // Group semantically similar openings under one family key so that
        // paraphrased variants of the same opening type (e.g. "company motivation"
        // and "role motivation") are not both chosen in consecutive practice runs.
        // CV and JD openings also include a short anchor identifier so that
        // different CV items or JD requirements are each tracked separately.
        switch target.dimension {
        case .cvExperience:
            let slug = target.anchor?.title
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .prefix(4)
                .joined(separator: "_") ?? "cv"
            return "CV|\(slug)"
        case .jdRequirement:
            let slug = target.anchor?.title
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .prefix(3)
                .joined(separator: "_") ?? "jd"
            return "JD|\(slug)"
        case .motivation:
            // Company-motivation and role-motivation openings are the same semantic
            // family — treat them identically so they are not used back-to-back.
            return "MOTIVATION"
        case .contextualOpening:
            return "BACKGROUND"
        case .technical:
            return "TECHNICAL"
        case .behavioral:
            return "BEHAVIORAL"
        case .collaboration:
            return "COLLABORATION"
        case .roleSpecific:
            return "ROLE_COMPETENCY"
        default:
            return "OTHER|\(target.dimension.rawValue)"
        }
    }
}

@MainActor
private enum BlueprintVariationMemory {
    private static let storageKey = "StepIN.recentBlueprintPatternKeys"
    private static let maxRecentCount = 8

    static func choosePattern(
        from patterns: [[InterviewBlueprintSlot]],
        context: InterviewContext
    ) -> [InterviewBlueprintSlot] {
        guard !patterns.isEmpty else { return [.opening, .background, .roleSpecific, .technical, .closing] }
        let recentKeys = persistedKeys()
        let selected = patterns.first { !recentKeys.contains(key(for: $0, context: context)) }
            ?? patterns.randomElement()
            ?? patterns[0]
        remember(selected, context: context)
        return selected
    }

    private static func remember(_ pattern: [InterviewBlueprintSlot], context: InterviewContext) {
        var keys = persistedKeys()
        keys.append(key(for: pattern, context: context))
        if keys.count > maxRecentCount {
            keys.removeFirst(keys.count - maxRecentCount)
        }
        UserDefaults.standard.set(keys, forKey: storageKey)
    }

    private static func persistedKeys() -> [String] {
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }

    private static func key(for pattern: [InterviewBlueprintSlot], context: InterviewContext) -> String {
        [
            context.jobTitle.lowercased(),
            "q\(context.questionCount)",
            context.hasCV ? "cv" : "no_cv",
            context.hasJD ? "jd" : "no_jd",
            context.company == nil ? "no_company" : "company",
            pattern.map(\.rawValue).joined(separator: ">")
        ].joined(separator: "|")
    }
}

enum AnswerRelevanceClassifier {
    static func classify(_ answer: String) -> AnswerRelevance {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .nonAnswer }

        let normalized = trimmed.lowercased()
        let words = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return .nonsenseOrFiller }

        let fillerOnly = Set(["um", "uh", "umm", "hmm", "like", "okay", "ok", "yeah", "yes", "no", "maybe"])
        if words.allSatisfy({ fillerOnly.contains($0) }) { return .nonsenseOrFiller }

        let nonAnswers = ["i don't know", "i dont know", "no idea", "skip", "pass", "nothing", "not sure", "i can't answer", "i cannot answer"]
        if nonAnswers.contains(where: { normalized.contains($0) }) && words.count <= 8 { return .nonAnswer }

        let offTopicPhrases = [
            "how can i cook", "how do i cook", "tell me a joke", "make me laugh", "pink or purple", "tie look better", "what should i wear", "weather", "recipe", "movie recommendation", "play music", "sing a song"
        ]
        if offTopicPhrases.contains(where: { normalized.contains($0) }) { return .offTopic }

        let profile = AnswerSignalProfile(answer)
        let hasInterviewEvidence = profile.hasProfessionalContext || profile.hasSpecificExample || profile.hasOwnContribution

        if words.count < 6 { return hasInterviewEvidence ? .partiallyRelevant : .nonAnswer }
        if profile.asksQuestion && !hasInterviewEvidence { return .offTopic }
        // Short professional first-person answers are relevant — brevity alone is not a
        // deficiency. "partiallyRelevant" is reserved for answers that genuinely did not
        // address the question (vague, off-topic, or lacking any interview substance).
        if profile.hasSpecificExample || (profile.hasProfessionalContext && profile.hasOwnContribution && words.count >= 8) {
            return .relevant
        }
        if hasInterviewEvidence || words.count >= 16 {
            return .partiallyRelevant
        }
        return .offTopic
    }
}

enum InterviewAnchorExtractor {
    static func cvAnchors(from text: String?, candidateFirstName: String = "") -> [InterviewAnchor] {
        guard let text = text?.orchestrationNilIfBlank else { return [] }
        let firstName = candidateFirstName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let grouped = cvEntryAnchors(from: text).filter { isEligibleAnchor($0, candidateFirstName: firstName) }
        if !grouped.isEmpty {
            return Array(grouped.prefix(10))
        }
        return anchors(from: text, source: .cv, preferredKeywords: [
            "project", "experience", "role", "skills", "technologies", "achievement", "responsible", "developed", "built", "created", "led", "managed", "intern", "engineer", "developer", "design", "testing", "automation", "research"
        ]).filter { isEligibleAnchor($0, candidateFirstName: firstName) }
    }

    private static func isEligibleAnchor(_ anchor: InterviewAnchor, candidateFirstName: String) -> Bool {
        guard anchor.kind != .unknown else { return false }
        if !candidateFirstName.isEmpty && anchor.title.lowercased().contains(candidateFirstName) {
            return false
        }
        return true
    }

    static func jdAnchors(from text: String?) -> [InterviewAnchor] {
        anchors(from: text, source: .jobDescription, preferredKeywords: [
            "required", "requirement", "responsibilities", "responsible", "must", "should", "experience", "skills", "collaborate", "build", "design", "develop", "manage", "lead", "communication", "technical", "testing", "analysis", "senior", "junior"
        ])
    }

    static func candidateLevel(cvText: String?, jobDescription: String?) -> String? {
        let text = [cvText, jobDescription].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if text.contains("senior") || text.contains("lead") || text.contains("principal") { return "senior/lead" }
        if text.contains("intern") || text.contains("graduate") || text.contains("junior") || text.contains("entry") { return "early-career" }
        if text.contains("years") || text.contains("experience") { return "experienced" }
        return nil
    }

    private static func anchors(from text: String?, source: InterviewAnchor.Source, preferredKeywords: [String]) -> [InterviewAnchor] {
        guard let text = text?.orchestrationNilIfBlank else { return [] }
        let lines = text
            .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ".;")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 12 }

        var scored: [(score: Int, anchor: InterviewAnchor)] = []
        for line in lines.prefix(80) {
            let lower = line.lowercased()
            let matched = preferredKeywords.filter { lower.contains($0) }
            let tech = technologyKeywords(in: line)
            let kind = anchorKind(for: lower, source: source, hasTechnology: !tech.isEmpty)
            let score = matched.count * 2 + tech.count + kind.priority + min(line.count / 80, 3)
            guard score > 0 else { continue }
            scored.append((score, InterviewAnchor(
                source: source,
                kind: kind,
                title: title(from: line),
                detail: String(line.prefix(220)),
                keywords: Array((matched + tech).prefix(8))
            )))
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.anchor.detail.count > rhs.anchor.detail.count }
            return lhs.score > rhs.score
        }
        return Array(sorted.map(\.anchor).prefix(8))
    }

    private struct CVEntry {
        let section: String
        let title: String
        let details: [String]
    }

    private static func cvEntryAnchors(from text: String) -> [InterviewAnchor] {
        let rawLines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard rawLines.count >= 3 else { return [] }

        var entries: [CVEntry] = []
        var currentSection = "general"
        var currentTitle: String?
        var currentDetails: [String] = []

        func flush() {
            guard let title = currentTitle?.orchestrationNilIfBlank else { return }
            // "general" is the pre-header candidate metadata block (name, email, phone) — never an interview topic.
            guard currentSection != "general" else { currentTitle = nil; currentDetails = []; return }
            let details = currentDetails.filter { !$0.isEmpty }
            guard !details.isEmpty || title.count >= 4 else { return }
            entries.append(CVEntry(section: currentSection, title: title, details: details.isEmpty ? [title] : details))
            currentTitle = nil
            currentDetails = []
        }

        for rawLine in rawLines.prefix(140) {
            let line = cleanedCVLine(rawLine)
            let lower = line.lowercased()
            if let section = cvSectionName(for: lower) {
                flush()
                currentSection = section
                continue
            }

            let trimmedRaw = rawLine.trimmingCharacters(in: .whitespaces)
            let isBullet = trimmedRaw.hasPrefix("-") || trimmedRaw.hasPrefix("•") || trimmedRaw.hasPrefix("*")
            let lineLooksLikeTitle = line.count <= 80
                && !line.hasSuffix(".")
                && !containsAny(lower, ["developed ", "built ", "implemented ", "responsible ", "managed ", "led ", "created ", "designed ", "tested "])

            if ["projects", "experience", "education", "certifications"].contains(currentSection), lineLooksLikeTitle, !isBullet {
                flush()
                currentTitle = line
                currentDetails = [line]
            } else if isBullet {
                if currentTitle == nil {
                    currentTitle = inferredEntryTitle(from: line, section: currentSection)
                }
                currentDetails.append(line)
            } else if currentTitle != nil {
                currentDetails.append(line)
            } else {
                currentTitle = inferredEntryTitle(from: line, section: currentSection)
                currentDetails = [line]
            }
        }
        flush()

        let scored = entries.map { entry -> (score: Int, anchor: InterviewAnchor) in
            let detail = entry.details.joined(separator: " ")
            let lower = "\(entry.title) \(detail)".lowercased()
            let tech = technologyKeywords(in: detail)
            let kind = cvEntryKind(section: entry.section, lowercasedText: lower, hasTechnology: !tech.isEmpty)
            let evidenceScore = kind.priority + tech.count + min(detail.count / 140, 3)
            let anchor = InterviewAnchor(
                source: .cv,
                kind: kind,
                title: entry.title,
                detail: String(detail.prefix(260)),
                keywords: Array((technologyKeywords(in: entry.title) + tech).prefix(8))
            )
            return (evidenceScore, anchor)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.anchor.detail.count > rhs.anchor.detail.count }
                return lhs.score > rhs.score
            }
            .map(\.anchor)
    }

    private static func cvSectionName(for lowercasedLine: String) -> String? {
        let normalized = lowercasedLine.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        switch normalized {
        case "projects", "selected projects", "academic projects", "portfolio":
            return "projects"
        case "experience", "work experience", "professional experience", "internship", "internships":
            return "experience"
        case "education":
            return "education"
        case "achievements", "achievement", "awards":
            return "achievements"
        case "certifications", "certificates":
            return "certifications"
        case "skills", "technical skills", "technologies":
            return "skills"
        default:
            return nil
        }
    }

    private static func cleanedCVLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inferredEntryTitle(from line: String, section: String) -> String {
        if section == "skills" { return "Technical skills" }
        if let first = line.components(separatedBy: CharacterSet(charactersIn: ":|-")).first?.orchestrationNilIfBlank, first.count <= 70 {
            return first
        }
        return title(from: line)
    }

    private static func cvEntryKind(section: String, lowercasedText: String, hasTechnology: Bool) -> InterviewAnchor.Kind {
        switch section {
        case "projects": return .project
        case "experience": return .experience
        case "achievements", "certifications", "education": return .achievement
        case "skills": return hasTechnology ? .technology : .skill
        default:
            return anchorKind(for: lowercasedText, source: .cv, hasTechnology: hasTechnology)
        }
    }

    private static func title(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet(charactersIn: ":-|")
        if let first = trimmed.components(separatedBy: separators).first?.orchestrationNilIfBlank, first.count <= 70 {
            return first
        }
        return String(trimmed.prefix(70))
    }

    private static func anchorKind(
        for lowercasedLine: String,
        source: InterviewAnchor.Source,
        hasTechnology: Bool
    ) -> InterviewAnchor.Kind {
        if source == .jobDescription {
            if containsAny(lowercasedLine, ["required", "requirement", "must", "should", "responsibilities", "responsible"]) {
                return .jdRequirement
            }
        }
        if containsAny(lowercasedLine, ["project", "capstone", "portfolio", "built", "created", "developed"]) {
            return .project
        }
        if containsAny(lowercasedLine, ["experience", "intern", "engineer", "developer", "designer", "analyst", "role"]) {
            return .experience
        }
        if containsAny(lowercasedLine, ["achievement", "improved", "reduced", "increased", "delivered", "awarded", "%"]) {
            return .achievement
        }
        if containsAny(lowercasedLine, ["responsible", "responsibilities", "owned", "managed", "led", "coordinated"]) {
            return .responsibility
        }
        if containsAny(lowercasedLine, ["skill", "skills", "proficient", "familiar"]) {
            return .skill
        }
        if hasTechnology {
            return .technology
        }
        return source == .jobDescription ? .jdRequirement : .unknown
    }

    private static func containsAny(_ text: String, _ signals: [String]) -> Bool {
        signals.contains { text.contains($0) }
    }

    private static func technologyKeywords(in line: String) -> [String] {
        let known = [
            "Swift", "SwiftUI", "UIKit", "iOS", "Python", "Java", "JavaScript", "TypeScript", "React", "Node", "SQL", "NoSQL", "AWS", "Azure", "Docker", "Kubernetes", "OpenAI", "Core ML", "ML", "AI", "Figma", "Excel", "Tableau", "Power BI", "Git", "API", "REST", "GraphQL"
        ]
        return known.filter { line.localizedCaseInsensitiveContains($0) }
    }
}

private extension InterviewAnchor.Kind {
    var priority: Int {
        switch self {
        case .project, .experience, .achievement:
            return 5
        case .jdRequirement, .responsibility:
            return 4
        case .technology, .skill:
            return 3
        case .roleContext:
            return 2
        case .unknown:
            return 0
        }
    }
}

private extension Optional where Wrapped == String {
    var orchestrationNilIfBlank: String? {
        guard let value = self else { return nil }
        return value.orchestrationNilIfBlank
    }
}

private extension String {
    var orchestrationNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
