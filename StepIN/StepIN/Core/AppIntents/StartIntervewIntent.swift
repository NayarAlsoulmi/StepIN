import AppIntents
import Foundation

struct StartInterviewIntent: AppIntent {
    
    static var title: LocalizedStringResource = "Start Interview"
    
    static var description = IntentDescription(
        "Starts a practice interview in StepIN."
    )
    
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        StepINNavigationBridge.requestStartInterview()
        return .result()
    }
}
