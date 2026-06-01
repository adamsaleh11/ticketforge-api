# TicketForge Web — Agent Instructions

## What this repo is

Next.js 14 (App Router) frontend for TicketForge. Users sign in with GitHub via Supabase Auth, describe a project, optionally link a GitHub repo, pick an LLM provider (Groq or local Ollama), and get back phased engineering tickets they can copy-paste into Claude Code or Codex.

**Auth is Supabase.** Sign-in is GitHub-only via Supabase OAuth. The Supabase session token is sent to the Rails backend as a Bearer token; Rails verifies it.

Backend lives in `ticketforge-api`. All app data comes from `NEXT_PUBLIC_API_URL`. Auth comes from Supabase directly.

## Stack

- Next.js 14 App Router, TypeScript strict mode
- Tailwind CSS + shadcn/ui (install per-component)
- `@supabase/supabase-js` + `@supabase/ssr` for auth
- Zustand for lightweight client state
- TanStack Query for server state
- axios for API calls (auth interceptor attaches Supabase session token)
- react-hook-form + zod for forms
- Deployed on Vercel free tier

## Design system — galaxy aesthetic

This is the product's soul. Don't water it down.

**Palette (Tailwind config):**

- `background`: `#0a0e27` (deep space navy)
- `foreground`: `#e4e6f1`
- `primary`: `#8b5cf6` (violet)
- `accent`: `#c084fc` (light violet)
- `muted`: `#1a1f3a`
- `border`: `rgba(139, 92, 246, 0.2)`

**Typography:**

- Headings: Space Grotesk
- Body: Inter

**Recurring elements:**

- `<Starfield />` canvas component — 200 twinkling particles, slow drift, fixed at `z-index: -10` in root layout.
- Radial nebula gradient overlay (purple → transparent) on root layout.
- Glassmorphism: `bg-white/5 backdrop-blur-md border border-white/10` — use for cards, modals, navbars.
- Violet glow on primary CTAs: `shadow-[0_0_30px_rgba(139,92,246,0.5)]`.
- Repo badges: frontend=violet, backend=blue, fullstack=violet→blue gradient, devops=orange.

## Project structure

```
app/
  (auth)/login                   # Full-screen galaxy, glassmorphic card
  auth/callback                  # Supabase OAuth return
  (app)/
    dashboard
    projects/[id]
    settings
    layout.tsx                   # Top nav, requires session
  layout.tsx                     # Root — mounts <Starfield />
  middleware.ts                  # Session refresh + route protection
components/
  ui/                            # shadcn — do not edit after install
  shared/                        # Starfield, GlassCard, RepoBadge, etc.
  features/                      # NewProjectDialog, TicketCard, OllamaSetupWizard, etc.
lib/
  supabase/
    client.ts                    # Browser client
    server.ts                    # Server client (SSR cookies)
  api.ts                         # axios instance + auth interceptor
  hooks/                         # useAuth, useProjects, useTickets, etc.
stores/                          # Zustand (auth UI state only)
```

## Hard rules

### TypeScript

1. Strict mode. No `any` unless explicitly justified in a comment.

### Auth

2. Sign-in is **GitHub OAuth via Supabase only**. No email/password. No other providers.
3. Request scopes: `public_repo read:user`. These come back in the Supabase session and Rails extracts them as `github_access_token`.
4. Use `@supabase/ssr` for the Next.js middleware-based session refresh pattern. Don't roll your own cookie management.
5. axios interceptor reads the session token via `supabase.auth.getSession()` and attaches as `Authorization: Bearer {token}`.
6. On 401 from backend: sign out via Supabase + redirect to /login.

### State management

7. **Server state = TanStack Query.** Never put server data in Zustand.
8. **Zustand = ephemeral client state only** (modal open/close that needs cross-component access, draft form data across steps).
9. **Auth state = Supabase client directly.** Use the `useAuth()` hook wrapping `supabase.auth.getSession()`.
10. Query keys are tuples: `['projects']`, `['project', id]`, `['github', 'repos']`.

### API calls

11. All API calls go through `lib/api.ts`. No bare `fetch` for app data.
12. Auth-related calls (sign in, sign out) go through the Supabase client, not axios.

### Forms

13. `react-hook-form` + `zod` resolver. No uncontrolled inputs. No `useState` for form fields.

### UX

14. **Loading states everywhere.** Every async UI element gets a shadcn `Skeleton` or spinner.
15. **Mobile responsive.** Test at 375px. Cards stack, nav collapses.
16. **Accessibility:** keyboard nav for all interactive elements, aria-labels on icons, WCAG AA contrast.

### shadcn

17. Install components as needed: `npx shadcn@latest add <component>`.
18. Don't edit `components/ui/` files after install. Style via CSS vars in `globals.css`.
19. Wrap shadcn components in feature components for business logic — keep `ui/` pure.

## Env vars

- `NEXT_PUBLIC_API_URL` — Rails backend URL (http://localhost:3001 in dev, Render URL in prod)
- `NEXT_PUBLIC_SUPABASE_URL` — Supabase project URL
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` — Supabase anon/public key

## What NOT to do

- **Don't use the Next.js Pages Router.** App Router only.
- **Don't add email/password sign-in.** GitHub OAuth via Supabase only.
- Don't add Redux, Jotai, Recoil, or any state library beyond Zustand + TanStack Query.
- Don't add a CSS-in-JS library. Tailwind only.
- Don't ship without loading skeletons.
- Don't break the galaxy aesthetic. If a component looks generic shadcn-default, add the violet, glassmorphism, glow.
- Don't fetch in server components for this MVP — keep everything client-side via TanStack Query.
- Don't store the Supabase session in localStorage manually. Let `@supabase/ssr` handle cookie-based storage.

## When stuck

Ask before guessing. Especially around: Supabase session refresh in middleware, OAuth redirect URLs, query invalidation patterns, Supabase RLS (we're not using RLS — all auth is in Rails).
