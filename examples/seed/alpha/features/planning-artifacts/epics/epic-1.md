# Epic 1: Task lifecycle

> Example artifact for the bmad-router `example` branch.

Deliver the core create → assign → complete loop across the `web` and `api` repos.

## Stories

### STORY-001 — Create a task (full-stack)

As a user, I want to create a task with a title and assignee so that work is
tracked. Touches **both** repos: a GraphQL `createTask` mutation in `api` and a
creation form in `web`. See `implementation-artifacts/STORY-001.md`.

### STORY-002 — Complete a task (api only)

As a user, I want to mark a task complete so that finished work drops off my open
list. Backend-only: a `completeTask` mutation and completion timestamp in `api`.

## Acceptance Criteria

1. A task can be created with a title and optional assignee.
2. A task can be marked complete, recording a completion timestamp.
3. The open/done filter reflects task status.
