# Project Context

<!-- Read by BMad agents before every workflow. -->

## Project Overview

- **Name**: Alpha
- **Description**: A demo full-stack task tracker, used here to show how bmad-router
  routes a single BMad core across multiple projects and how one story can span
  several source repos.
- **Tech Stack**: React + TypeScript web app (`web` repo), Node + GraphQL API
  (`api` repo), Postgres.

## Implementation Rules

- All API mutations validate input with zod before touching the database.
- React components are function components with hooks — no class components.
- Every story ships with tests for its business logic.
- Cross-repo changes for one story share the branch name `story/<story-id>`.

## Conventions

- Conventional Commits (`feat:`, `fix:`, `chore:`).
- Source repos are declared in `repos.yaml`; implement inside the per-story
  worktrees under `implementation/<story-id>/<repo>/`, never in `repos/` directly.
