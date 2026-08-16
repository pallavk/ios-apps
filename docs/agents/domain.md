# Domain Docs

How engineering skills consume this repository's domain documentation.

## Before exploring

- Read `CONTEXT.md` at the repository root when it exists.
- If a future `CONTEXT-MAP.md` exists, read the context files relevant to the current app.
- Read ADRs under `docs/adr/` that touch the area being changed.
- If these files do not exist, proceed silently. Domain-modeling skills create them when real terminology or durable decisions emerge.

## Current layout

Use a single root context for now:

```text
/
├── CONTEXT.md
├── docs/adr/
└── apps/
```

Introduce `CONTEXT-MAP.md` and app-specific context files only when the repository contains enough independent domain language that one root glossary becomes confusing.

## Vocabulary

Use terms as defined in `CONTEXT.md` in issue titles, specifications, tests, and code. Avoid drifting to synonyms that the glossary rejects.

If a needed concept is absent, reconsider whether it is existing repository language or a genuine gap for `domain-modeling`.

## ADR conflicts

If proposed work contradicts an existing ADR, surface the conflict explicitly rather than silently overriding the decision.
