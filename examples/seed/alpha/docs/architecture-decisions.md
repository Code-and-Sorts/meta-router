# Architecture Decisions — Alpha

> Example `project_knowledge` doc for the meta-router `example` branch.

## ADR-001: Shared GraphQL schema is the contract between web and api

**Status**: Accepted

**Context**: Alpha spans two repos (`web`, `api`). Drift between the front end's
expectations and the API's responses is the most likely source of bugs.

**Decision**: The GraphQL schema is the single source of truth. The `api` repo
owns the schema; `web` generates its types from it. A story that changes the
contract touches both repos and is implemented across both worktrees on the same
`story/<id>` branch.

**Consequences**: Contract changes are reviewed as a pair of PRs (one per repo)
sharing a branch name, keeping the two sides in lockstep.
