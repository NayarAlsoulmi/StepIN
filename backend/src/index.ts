// StepIN backend — lightweight and secure.
// Responsibilities: temporary realtime sessions, interview analysis,
// validation, rate limiting. It stores NO permanent user data.

import "dotenv/config";
import express from "express";
import { z } from "zod";
import {
  MockProvider,
  ProductionProvider,
  type RealtimeAIProvider,
  type AnalysisAIProvider,
} from "./providers.js";

const app = express();
app.use(express.json({ limit: "1mb" }));

// --- CORS -------------------------------------------------------------
const allowedOrigin = process.env.ALLOWED_ORIGIN ?? "*";
app.use((_req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", allowedOrigin);
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  next();
});

// --- Provider selection ------------------------------------------------
function buildProvider(): RealtimeAIProvider & AnalysisAIProvider {
  if (process.env.AI_PROVIDER === "production") {
    return new ProductionProvider(
      process.env.AI_PROVIDER_API_KEY ?? "",
      process.env.AI_REALTIME_MODEL ?? "",
      process.env.AI_ANALYSIS_MODEL ?? ""
    );
  }
  return new MockProvider();
}
const provider = buildProvider();

// --- Basic in-memory rate limiting -------------------------------------
const windowMs = Number(process.env.RATE_LIMIT_WINDOW_MS ?? 60_000);
const maxRequests = Number(process.env.RATE_LIMIT_MAX_REQUESTS ?? 30);
const hits = new Map<string, { count: number; windowStart: number }>();

app.use((req, res, next) => {
  const key = req.ip ?? "unknown";
  const now = Date.now();
  const entry = hits.get(key);
  if (!entry || now - entry.windowStart > windowMs) {
    hits.set(key, { count: 1, windowStart: now });
    return next();
  }
  entry.count += 1;
  if (entry.count > maxRequests) {
    return res.status(429).json(errorBody("rate_limited", "Too many requests.", true));
  }
  next();
});

// --- Error format -------------------------------------------------------
function errorBody(code: string, message: string, recoverable: boolean) {
  return { code, message, recoverable, requestID: crypto.randomUUID() };
}

// --- Schemas ------------------------------------------------------------
const sessionSchema = z.object({
  jobTitle: z.string().trim().min(1).max(200),
  company: z.string().trim().max(200).optional(),
  companyWebsite: z.string().trim().max(500).optional(),
  jobDescription: z.string().trim().max(20_000).optional(),
  resolvedCVText: z.string().trim().max(50_000).optional(),
  questionCount: z.union([z.literal(5), z.literal(10), z.literal(15), z.literal(20)]),
  candidateFirstName: z.string().trim().min(1).max(100),
  sessionID: z.string().trim().min(1).max(100),
});

const analysisSchema = z.object({
  interviewID: z.string().trim().min(1).max(100),
  jobTitle: z.string().trim().min(1).max(200),
  company: z.string().trim().max(200).optional(),
  jobDescription: z.string().trim().max(20_000).optional(),
  resolvedCVText: z.string().trim().max(50_000).optional(),
  selectedQuestionCount: z.number().int().min(5).max(20),
  completedQuestionCount: z.number().int().min(0).max(40),
  isPartial: z.boolean(),
  transcript: z
    .array(
      z.object({
        speaker: z.enum(["interviewer", "candidate"]),
        text: z.string().max(20_000),
        sequence: z.number().int().min(0),
      })
    )
    .min(1)
    .max(200),
  aggregatedSpeechMetrics: z.record(z.unknown()).optional(),
});

// --- Endpoints ----------------------------------------------------------

app.get("/api/health", (_req, res) => {
  res.json({ status: "ok", version: "0.1.0", timestamp: new Date().toISOString() });
});

app.post("/api/realtime/session", async (req, res) => {
  const parsed = sessionSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json(errorBody("invalid_request", "Invalid session request.", true));
  }
  try {
    const session = await withTimeout(provider.createSession(parsed.data), 10_000);
    res.json(session);
  } catch {
    res
      .status(502)
      .json(errorBody("session_failed", "Could not create an interview session.", true));
  }
});

app.post("/api/interviews/analyze", async (req, res) => {
  const parsed = analysisSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json(errorBody("invalid_request", "Invalid analysis request.", true));
  }
  try {
    const analysis = await withTimeout(provider.analyze(parsed.data), 60_000);
    res.json(analysis);
  } catch {
    res
      .status(502)
      .json(errorBody("analysis_failed", "Could not generate the analysis.", true));
  }
});

// --- Helpers ------------------------------------------------------------
function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timeout")), ms)),
  ]);
}

const port = Number(process.env.PORT ?? 3000);
app.listen(port, () => {
  console.log(`StepIN backend listening on :${port} (provider: ${process.env.AI_PROVIDER ?? "mock"})`);
});
