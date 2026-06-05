# Alpha — Product Requirements Document

> Example artifact. Generated for the bmad-router `example` branch to show what a
> populated project looks like.

## Summary

Alpha is a small task tracker. Users create tasks, assign them, and mark them
done. It exists to demonstrate a full-stack BMad project whose stories span both
a web front end and a GraphQL API.

## Goals

- Let a user create, assign, and complete tasks.
- Surface a per-user task list filtered by status.
- Keep the web and API repos in sync via a shared GraphQL schema.

## Functional Requirements

1. **FR-1** — A user can create a task with a title and optional assignee.
2. **FR-2** — A user can mark a task complete; completion is timestamped.
3. **FR-3** — The task list can be filtered by status (open, done).

## Non-Functional Requirements

- **NFR-1** — API mutations respond in under 200ms p95.
- **NFR-2** — The web bundle stays under 250KB gzipped.

## Success Criteria

- A user can complete the create → assign → done loop end to end.
- The shared GraphQL schema is the single source of truth for both repos.
