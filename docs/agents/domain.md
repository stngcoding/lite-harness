# Domain Documentation

## Layout: Single-context

This project has a single domain context:
- **Root domain doc:** `CONTEXT.md` (not yet created; see below)
- **Architecture decisions:** `docs/adr/` (create as needed)

No `CONTEXT-MAP.md` is needed.

## Creating CONTEXT.md

When you're ready, create `CONTEXT.md` at the repo root. This file helps engineering skills understand the project's domain language and architecture.

Include:
- **Project purpose** — one paragraph on what the project does
- **Key entities** — the core domain concepts (users, orders, features, etc.)
- **Architecture** — high-level layers/modules and how they talk
- **Constraints** — any important limitations or conventions

Example structure:
```markdown
# CONTEXT

## Purpose
[one paragraph]

## Entities
- EntityA: description
- EntityB: description

## Architecture
[layers/modules + how they interact]

## Constraints & Conventions
- [constraint 1]
- [constraint 2]
```

## Creating Architecture Decision Records (ADRs)

When making significant architectural decisions, document them in `docs/adr/`:

```
docs/adr/
  001-technology-choice.md
  002-schema-design.md
  ...
```

Each ADR should include:
- **Title** — short, descriptive
- **Status** — Proposed, Accepted, Deprecated, Superseded
- **Context** — the issue/problem
- **Decision** — what was decided and why
- **Consequences** — trade-offs and implications

Skills like `improve-codebase-architecture` and `diagnose` will read these to understand past decisions and avoid contradicting them.
