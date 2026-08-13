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
        cvAnchors = InterviewAnchorExtractor.cvAnchors(from: cvText)
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

    let source: Source
    let title: String
    let detail: String
    let keywords: [String]

    var promptLine: String {
        let keywordText = keywords.isEmpty ? "" : " Keywords: \(keywords.prefix(6).joined(separator: ", "))."
        return "\(source.rawValue): \(title). \(detail)\(keywordText)"
    }
}

enum InterviewCoverageDimension: String, Sendable {
    case contextualOpening = "contextual opening"
    case cvExperience = "CV/project experience"
    case roleSpecific = "role-specific competency"
    case behavioral = "behavioral competency"
    case technical = "technical/domain competency"
    case jdRequirement = "job-description requirement"
    case collaboration = "collaboration/communication"
    case motivation = "role/company motivation"
    case adaptiveFollowUp = "adaptive follow-up"
    case closingSubstantive = "closing substantive question"
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
}

@MainActor
final class InterviewConversationController {
    private let plan: InterviewPlan
    private var targetIndex: Int
    private var coveredTargetIDs: Set<UUID> = []
    private var followUpDepthByTargetID: [UUID: Int] = [:]
    private var lastTargetID: UUID?
    private var lastRelevance: AnswerRelevance = .relevant
    private var closingOpportunityAsked = false
    private var completedSubstantiveQuestions = 0

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
            lastTargetID = active.id
            logCurrent(action: "follow_up", target: active, relevance: relevance)
            return .followUp(active, relevance)
        }

        markCovered(active)
        let next = nextUncoveredTarget(after: active) ?? active
        targetIndex = plan.targets.firstIndex(of: next) ?? targetIndex
        lastTargetID = next.id
        logCurrent(action: "next_target", target: next, relevance: relevance)
        return .nextTarget(next, relevance)
    }

    func markAssistantTurnCompleted(counted: Bool, text: String) {
        if counted {
            completedSubstantiveQuestions = min(completedSubstantiveQuestions + 1, plan.context.questionCount)
        }

        guard let lastTargetID else { return }
        if counted, let target = plan.targets.first(where: { $0.id == lastTargetID }) {
            if case .adaptiveFollowUp = target.dimension {
                return
            }
        }
    }

    func instructions(for action: InterviewNextAction, language: String) -> String {
        switch action {
        case .firstQuestion(let target):
            return questionInstruction(
                prefix: "Ask the first real counted interview question now",
                target: target,
                language: language,
                extra: "Use this opening intent to avoid generic repeated openers. Do not greet again. Do not mention question numbers. Ask one question only."
            )

        case .followUp(let target, let relevance):
            let relevanceLine = relevance == .partiallyRelevant
                ? "The answer was related but incomplete; acknowledge only the useful part briefly, then ask a specific follow-up."
                : "Ask one strong follow-up only because the answer introduced useful depth or an unresolved detail."
            return questionInstruction(
                prefix: "Ask a counted follow-up question",
                target: target,
                language: language,
                extra: "\(relevanceLine) Do not drill beyond this target's follow-up budget."
            )

        case .nextTarget(let target, let relevance):
            let transition = relevance == .partiallyRelevant
                ? "The previous answer was related but incomplete; briefly refocus if needed, then transition."
                : "Transition naturally from the previous answer if useful."
            return questionInstruction(
                prefix: "Move to the next counted coverage target",
                target: target,
                language: language,
                extra: "\(transition) Ask one question only."
            )

        case .redirect(let target, let relevance):
            let redirect = relevance == .nonAnswer || relevance == .nonsenseOrFiller
                ? "The candidate did not provide a usable interview answer. Give one brief clarification or repeat the question in a clearer form."
                : "The candidate went off topic. Do not answer their unrelated request. Briefly redirect to the interview."
            return questionInstruction(
                prefix: "Redirect without spending a counted question",
                target: target,
                language: language,
                extra: "\(redirect) Do not say this was helpful context unless it contained real interview content. Keep it short and professional."
            )

        case .closingOpportunity:
            return """
            In \(language), ask only the existing uncounted closing opportunity: "Before we wrap up, is there anything you'd like to ask or add?" Do not ask a new scored interview question. Stop after the closing opportunity and wait.
            """

        case .finalClose:
            return """
            Say exactly: "Thank you. That concludes our interview." Do not add any other sentence, question, feedback, score, or commentary.
            """
        }
    }

    private var currentTarget: InterviewCoverageTarget {
        plan.targets[min(max(targetIndex, 0), plan.targets.count - 1)]
    }

    private func shouldFollowUp(
        answer: String,
        relevance: AnswerRelevance,
        countedQuestionCount: Int,
        target: InterviewCoverageTarget
    ) -> Bool {
        guard relevance.containsInterviewEvidence else { return false }
        let remainingSlots = plan.context.questionCount - countedQuestionCount
        guard remainingSlots > remainingRequiredTargets(after: target) else { return false }

        let currentDepth = followUpDepthByTargetID[target.id] ?? 0
        guard currentDepth < target.maxFollowUps else { return false }

        let wordCount = answer.split(separator: " ").count
        let lowercased = answer.lowercased()
        let unresolvedSignals = ["because", "but", "challenge", "hard", "difficult", "decided", "trade", "result", "impact", "learned", "mistake", "validation", "tested", "led", "owned"]
        let hasSignal = unresolvedSignals.contains { lowercased.contains($0) }
        let isWeakButRelevant = relevance == .partiallyRelevant || wordCount < 18
        let usefulDepth = wordCount >= 24 && hasSignal

        if isWeakButRelevant { return currentDepth == 0 }
        if usefulDepth { return currentDepth < min(target.maxFollowUps, 2) }
        return false
    }

    private func remainingRequiredTargets(after target: InterviewCoverageTarget) -> Int {
        let remaining = plan.targets.filter { !coveredTargetIDs.contains($0.id) && $0.id != target.id }
        return min(remaining.count, max(0, plan.context.questionCount - completedSubstantiveQuestions - 1))
    }

    private func markCovered(_ target: InterviewCoverageTarget) {
        coveredTargetIDs.insert(target.id)
    }

    private func nextUncoveredTarget(after target: InterviewCoverageTarget) -> InterviewCoverageTarget? {
        guard let start = plan.targets.firstIndex(of: target) else {
            return plan.targets.first { !coveredTargetIDs.contains($0.id) }
        }

        for offset in 1...plan.targets.count {
            let index = (start + offset) % plan.targets.count
            let candidate = plan.targets[index]
            if !coveredTargetIDs.contains(candidate.id) {
                return candidate
            }
        }
        return nil
    }

    private func questionInstruction(prefix: String, target: InterviewCoverageTarget, language: String, extra: String) -> String {
        let covered = coveredTargetsLine
        let remaining = remainingTargetsLine(current: target)
        let anchorLine = target.anchor.map { "Source anchor: \($0.promptLine)" } ?? "Source anchor: none"
        return """
        \(prefix) in \(language).
        Current coverage target: \(target.dimension.rawValue).
        Intent: \(target.intent).
        \(anchorLine)
        Covered so far: \(covered).
        Remaining priority: \(remaining).
        Substantive counted questions completed by Swift: \(completedSubstantiveQuestions) of \(plan.context.questionCount).
        Follow-up depth on this target: \(followUpDepthByTargetID[target.id] ?? 0) of \(target.maxFollowUps).
        \(contextLines)
        \(extra)
        The app decides this target; phrase the question naturally and do not expose the plan.
        """
    }

    private var contextLines: String {
        var lines = ["Job title: \(plan.context.jobTitle)"]
        if let company = plan.context.company { lines.append("Company: \(company)") }
        if let level = plan.context.candidateLevel { lines.append("Candidate level signal: \(level)") }
        if plan.context.hasCV { lines.append("CV anchors available: \(plan.context.cvAnchors.prefix(4).map(\.title).joined(separator: "; "))") }
        if plan.context.hasJD { lines.append("JD anchors available: \(plan.context.jdAnchors.prefix(4).map(\.title).joined(separator: "; "))") }
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
        print("[StepIN.Orchestration] planned targets:")
        for (index, target) in plan.targets.enumerated() {
            print("[StepIN.Orchestration] \(index + 1). \(target.debugLabel), followUps=\(target.maxFollowUps)")
        }
        #endif
    }

    private func logCurrent(action: String, target: InterviewCoverageTarget, relevance: AnswerRelevance?) {
        #if DEBUG
        let relevanceText = relevance?.rawValue ?? "n/a"
        let anchor = target.anchor.map { "\($0.source.rawValue): \($0.title)" } ?? "none"
        print("[StepIN.Orchestration] action=\(action), target=\(target.dimension.rawValue), intent=\(target.intent), anchor=\(anchor), followDepth=\(followUpDepthByTargetID[target.id] ?? 0)/\(target.maxFollowUps), relevance=\(relevanceText), counted=\(completedSubstantiveQuestions)/\(plan.context.questionCount), covered=\(coveredTargetIDs.count)")
        #endif
    }
}

@MainActor
enum InterviewPlanner {
    static func makePlan(context: InterviewContext) -> InterviewPlan {
        let maxFollowUps = context.questionCount >= 15 ? 3 : (context.questionCount >= 10 ? 2 : 1)
        var targets: [InterviewCoverageTarget] = []

        let openingCandidates = openingTargets(context: context, maxFollowUps: maxFollowUps)
        let opening = OpeningDiversityMemory.chooseOpening(
            from: openingCandidates,
            fallback: roleTarget(context: context, maxFollowUps: maxFollowUps)
        )
        targets.append(opening)

        targets += requiredCVTargets(context: context, maxFollowUps: maxFollowUps)
        targets += requiredJDTargets(context: context, maxFollowUps: maxFollowUps)
        targets += baselineTargets(context: context, maxFollowUps: maxFollowUps)

        var unique: [InterviewCoverageTarget] = []
        var seen = Set<String>()
        for target in targets {
            let key = "\(target.dimension.rawValue)-\(target.anchor?.title ?? target.intent)"
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(target)
            }
        }

        let capped = Array(unique.prefix(max(context.questionCount, 1)))
        return InterviewPlan(context: context, targets: capped.isEmpty ? [opening] : capped, openingTargetID: opening.id)
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
                anchor: InterviewAnchor(source: .company, title: company, detail: "Provided company context only.", keywords: []),
                maxFollowUps: 1
            ))
        }
        targets.append(InterviewCoverageTarget(
            dimension: .contextualOpening,
            intent: "open on the candidate's most relevant recent experience for the \(context.jobTitle) role",
            anchor: InterviewAnchor(source: .role, title: "\(context.jobTitle) background", detail: "Use the target role only; do not ask a generic tell-me-about-yourself question unless it is made role-specific.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        ))
        targets.append(InterviewCoverageTarget(
            dimension: .motivation,
            intent: "open on why this role direction fits the candidate's goals or background",
            anchor: InterviewAnchor(source: .role, title: "\(context.jobTitle) motivation", detail: "Role motivation from setup data only.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: 1
        ))
        targets.append(InterviewCoverageTarget(
            dimension: .technical,
            intent: "open on practical role-specific experience or judgment",
            anchor: InterviewAnchor(source: .role, title: "\(context.jobTitle) practical experience", detail: "Ask for evidence relevant to the target role.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        ))
        targets.append(InterviewCoverageTarget(
            dimension: .behavioral,
            intent: "open with a role-relevant ownership or problem-solving example",
            anchor: InterviewAnchor(source: .role, title: "\(context.jobTitle) ownership", detail: "Ask for a concrete professional, academic, or project example relevant to the role.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        ))
        targets.append(InterviewCoverageTarget(
            dimension: .collaboration,
            intent: "open on communication or collaboration expected in the target role",
            anchor: InterviewAnchor(source: .role, title: "\(context.jobTitle) collaboration", detail: "Use general role expectations only.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        ))
        targets.append(roleTarget(context: context, maxFollowUps: maxFollowUps))
        return targets
    }

    private static func requiredCVTargets(context: InterviewContext, maxFollowUps: Int) -> [InterviewCoverageTarget] {
        guard context.hasCV else { return [] }
        let targetCount = context.questionCount <= 5 ? 1 : (context.questionCount <= 10 ? 2 : 3)
        return context.cvAnchors.prefix(targetCount).map { anchor in
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
        var targets = [
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

        if context.questionCount >= 10 {
            targets.append(InterviewCoverageTarget(
                dimension: .technical,
                intent: "probe practical domain knowledge, trade-offs, and decision quality for the role",
                anchor: nil,
                maxFollowUps: maxFollowUps
            ))
        }

        if context.questionCount >= 15 {
            targets.append(InterviewCoverageTarget(
                dimension: .adaptiveFollowUp,
                intent: "reserve one adaptive slot for the strongest unresolved evidence from earlier answers",
                anchor: InterviewAnchor(source: .adaptive, title: "adaptive evidence", detail: "Use only details introduced in this interview.", keywords: []),
                maxFollowUps: 1
            ))
        }

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
            anchor: InterviewAnchor(source: .role, title: context.jobTitle, detail: "Target role from interview setup.", keywords: context.jobTitle.split(separator: " ").map(String.init)),
            maxFollowUps: maxFollowUps
        )
    }
}

@MainActor
private enum OpeningDiversityMemory {
    private static var recentOpeningKeys: [String] = []
    private static let maxRecentCount = 6

    static func chooseOpening(
        from candidates: [InterviewCoverageTarget],
        fallback: InterviewCoverageTarget
    ) -> InterviewCoverageTarget {
        let usableCandidates = candidates.isEmpty ? [fallback] : candidates
        let preferred = usableCandidates.first { !recentOpeningKeys.contains(key(for: $0)) }
        let selected = preferred ?? usableCandidates.randomElement() ?? fallback
        remember(selected)
        return selected
    }

    private static func remember(_ target: InterviewCoverageTarget) {
        recentOpeningKeys.append(key(for: target))
        if recentOpeningKeys.count > maxRecentCount {
            recentOpeningKeys.removeFirst(recentOpeningKeys.count - maxRecentCount)
        }
    }

    private static func key(for target: InterviewCoverageTarget) -> String {
        [
            target.dimension.rawValue,
            target.anchor?.source.rawValue ?? "none",
            target.anchor?.title.lowercased() ?? target.intent.lowercased()
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

        let interviewSignals = [
            "project", "role", "team", "work", "job", "experience", "skill", "built", "created", "developed", "designed", "managed", "led", "learned", "challenge", "result", "impact", "customer", "user", "data", "testing", "technical", "communication", "collaboration", "company", "responsibility"
        ]
        let signalCount = interviewSignals.reduce(0) { $0 + (normalized.contains($1) ? 1 : 0) }

        if words.count < 6 { return signalCount > 0 ? .partiallyRelevant : .nonAnswer }
        if signalCount == 0 && normalized.contains("?") { return .offTopic }
        if signalCount == 0 && words.count < 14 { return .partiallyRelevant }
        return signalCount >= 1 ? .relevant : .partiallyRelevant
    }
}

enum InterviewAnchorExtractor {
    static func cvAnchors(from text: String?) -> [InterviewAnchor] {
        anchors(from: text, source: .cv, preferredKeywords: [
            "project", "experience", "role", "skills", "technologies", "achievement", "responsible", "developed", "built", "created", "led", "managed", "intern", "engineer", "developer", "design", "testing", "automation", "research"
        ])
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
            let score = matched.count * 2 + tech.count + min(line.count / 80, 3)
            guard score > 0 else { continue }
            scored.append((score, InterviewAnchor(
                source: source,
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

    private static func title(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet(charactersIn: ":-|")
        if let first = trimmed.components(separatedBy: separators).first?.orchestrationNilIfBlank, first.count <= 70 {
            return first
        }
        return String(trimmed.prefix(70))
    }

    private static func technologyKeywords(in line: String) -> [String] {
        let known = [
            "Swift", "SwiftUI", "UIKit", "iOS", "Python", "Java", "JavaScript", "TypeScript", "React", "Node", "SQL", "NoSQL", "AWS", "Azure", "Docker", "Kubernetes", "OpenAI", "Core ML", "ML", "AI", "Figma", "Excel", "Tableau", "Power BI", "Git", "API", "REST", "GraphQL"
        ]
        return known.filter { line.localizedCaseInsensitiveContains($0) }
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
