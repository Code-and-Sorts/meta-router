# Shared Context

<!-- Read by BMad agents before every workflow, for every project, alongside the
     active project's project-context.md. Project context wins on conflict. -->

## Overview

- **Organization / Team**: Acme Apps
- **Mission**: Ship small, well-tested full-stack products that share one BMad core.
- **Scope**: Conventions here apply to every project under projects/ (alpha, beta, ...).

## Org-wide Tech Standards

- Node.js 20 LTS for all services.
- TypeScript in strict mode everywhere — no implicit `any`.
- Postgres is the default relational store.
- Inputs at trust boundaries (API mutations, request handlers) validate with zod.

## Cross-cutting Conventions

- Conventional Commits (`feat:`, `fix:`, `chore:`) across all repos.
- One story shares the branch name `story/<story-id>` across every affected repo.
- Every story ships with tests for its business logic.
- React UIs use function components with hooks — no class components.

## Shared Constraints

- No secrets in source — use the org secret manager / CI secrets.
- All public APIs require authentication and input validation.
- Dependencies must use OSI-approved licenses.

## Precedence

Project-specific guidance in features/project-context.md overrides this file when
the two conflict. This file is the default for anything a project does not specify.
