# Project Context

## Project Overview

- **Name**: Beta
- **Description**: A demo single-repo CLI tool, included to contrast with the
  multi-repo `alpha` project — its stories default to the one configured repo.
- **Tech Stack**: Go CLI (`cli` repo).

## Implementation Rules

- Commands live under `cmd/`; shared logic under `internal/`.
- Every command has a table-driven test.

## Conventions

- Conventional Commits. Implement inside the per-story worktree under
  `implementation/<story-id>/cli/`.
