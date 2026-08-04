# StepIN Backend

Lightweight secure backend for the StepIN iOS app. It protects AI credentials,
creates temporary realtime sessions, and generates interview analysis. It
stores **no permanent user data** — all profile/interview/goal data lives on
the device.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/health` | Health check (status, version, timestamp) |
| POST | `/api/realtime/session` | Mint a temporary realtime AI credential |
| POST | `/api/interviews/analyze` | Generate structured interview analysis |

## Local development

```bash
cd backend
npm install
cp .env.example .env    # defaults to the mock provider — no API key needed
npm run dev
```

Verify:

```bash
curl http://localhost:3000/api/health
```

## Environments

- `AI_PROVIDER=mock` — no key required; deterministic-ish sample responses.
- `AI_PROVIDER=production` — requires `AI_PROVIDER_API_KEY`,
  `AI_REALTIME_MODEL`, `AI_ANALYSIS_MODEL`. The production adapter is a shell
  until Phase 6 (realtime voice integration).

Never commit `.env`. Rate limiting, request validation (zod), timeouts, and a
safe error format (`code`, `message`, `recoverable`, `requestID`) are applied
to all endpoints.

## Deployment

Any simple Node platform works (Render, Railway, Cloud Run, Vercel). Build
with `npm run build`, start with `npm start`, set env vars in the platform's
dashboard, and always serve over HTTPS.
