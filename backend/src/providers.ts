// Provider abstraction. Business logic depends on these interfaces —
// never on a specific AI vendor.

export interface RealtimeSessionRequest {
  jobTitle: string;
  company?: string;
  companyWebsite?: string;
  jobDescription?: string;
  resolvedCVText?: string;
  questionCount: 5 | 10 | 15 | 20;
  candidateFirstName: string;
  sessionID: string;
}

export interface RealtimeSessionResponse {
  temporaryCredential: string;
  expiresAt: string; // ISO timestamp
  realtimeModel: string;
  sessionConfiguration: Record<string, unknown>;
}

export interface TranscriptEntry {
  speaker: "interviewer" | "candidate";
  text: string;
  sequence: number;
}

export interface AnalysisRequest {
  interviewID: string;
  jobTitle: string;
  company?: string;
  jobDescription?: string;
  resolvedCVText?: string;
  selectedQuestionCount: number;
  completedQuestionCount: number;
  isPartial: boolean;
  transcript: TranscriptEntry[];
  aggregatedSpeechMetrics?: Record<string, unknown>;
}

export interface AnalysisResponse {
  overallScore: number;
  categoryScores: {
    answerQuality: number;
    clarity: number;
    confidence: number;
    communication: number;
    interviewSkills: number;
  };
  strengths: string[];
  areasToImprove: string[];
  assignedGoals: string[];
  summary: string;
}

export interface RealtimeAIProvider {
  createSession(req: RealtimeSessionRequest): Promise<RealtimeSessionResponse>;
}

export interface AnalysisAIProvider {
  analyze(req: AnalysisRequest): Promise<AnalysisResponse>;
}

// ---------------------------------------------------------------------------
// Mock provider — powers local development and the demo without any API key.
// ---------------------------------------------------------------------------

export class MockProvider implements RealtimeAIProvider, AnalysisAIProvider {
  async createSession(req: RealtimeSessionRequest): Promise<RealtimeSessionResponse> {
    return {
      temporaryCredential: `mock-credential-${req.sessionID}`,
      expiresAt: new Date(Date.now() + 5 * 60_000).toISOString(),
      realtimeModel: "mock-realtime-v1",
      sessionConfiguration: {
        voice: "professional",
        interviewerPromptVersion: "1.0.0",
        questionCount: req.questionCount,
      },
    };
  }

  async analyze(req: AnalysisRequest): Promise<AnalysisResponse> {
    const candidateTurns = req.transcript.filter((t) => t.speaker === "candidate");
    const avgWords =
      candidateTurns.length === 0
        ? 0
        : candidateTurns.reduce((sum, t) => sum + t.text.split(/\s+/).length, 0) /
          candidateTurns.length;

    let base = 70;
    if (avgWords > 25) base += 8;
    if (req.isPartial) base -= 8;
    base = Math.min(Math.max(base, 55), 92);
    const vary = (d: number) => Math.min(Math.max(base + d, 50), 96);

    const scores = {
      answerQuality: vary(3),
      clarity: vary(1),
      confidence: vary(-4),
      communication: vary(2),
      interviewSkills: vary(0),
    };
    const overall = Math.round(
      (scores.answerQuality + scores.clarity + scores.confidence +
        scores.communication + scores.interviewSkills) / 5
    );

    return {
      overallScore: overall,
      categoryScores: scores,
      strengths: [
        "You supported your answers with concrete examples from your projects.",
        "You stayed calm and composed throughout the interview.",
        `You showed genuine motivation for the ${req.jobTitle} role.`,
      ],
      areasToImprove: [
        "Try making your answers more concise while keeping the important details.",
        "Practice structuring behavioral answers around the situation, your actions, and the result.",
        "Practice speaking with fewer pauses to keep your delivery consistent.",
      ],
      assignedGoals: [
        "Practice answering behavioral questions using specific examples.",
        "Practice concise introductions.",
      ],
      summary: req.isPartial
        ? `A promising partial interview for the ${req.jobTitle} role.`
        : `A solid interview for the ${req.jobTitle} role with clear examples.`,
    };
  }
}

// ---------------------------------------------------------------------------
// Production provider — adapter shell for a realtime voice-capable AI vendor.
// Reads credentials from environment only. Wire up in Phase 6.
// ---------------------------------------------------------------------------

export class ProductionProvider implements RealtimeAIProvider, AnalysisAIProvider {
  constructor(
    private apiKey: string,
    private realtimeModel: string,
    private analysisModel: string
  ) {
    if (!apiKey) throw new Error("AI_PROVIDER_API_KEY is required for production provider");
  }

  async createSession(_req: RealtimeSessionRequest): Promise<RealtimeSessionResponse> {
    // TODO(Phase 6): mint an ephemeral realtime credential from the vendor
    // and return it. Permanent keys must never reach the app.
    throw new Error("Production realtime provider not configured yet");
  }

  async analyze(_req: AnalysisRequest): Promise<AnalysisResponse> {
    // TODO(Phase 6): call the analysis model with the centralized coach
    // prompt and validate the structured response.
    throw new Error("Production analysis provider not configured yet");
  }
}
