# Alpha Tasks - Epic Breakdown

> Example artifact for the bmad-router `example` branch, in the BMad v6
> epics.md shape (`## Epic N:` / `### Story N.M:` headers — the GitHub sync
> joins these to development_status keys by the epic/story numbers).

## Epic List

## Epic 1: Task lifecycle

Deliver the core create → assign → complete loop across the `web` and `api` repos.

### Story 1.1: Create a task (full-stack)

As a user, I want to create a task with a title and assignee, so that work is
tracked. Touches **both** repos: a GraphQL `createTask` mutation in `api` and a
creation form in `web`. See `implementation-artifacts/1-1-create-a-task.md`.

**Acceptance Criteria:**

**Given** the web app **When** a task is created with a title and optional
assignee **Then** it persists via `createTask` **And** appears in the open list.

### Story 1.2: Complete a task (api only)

As a user, I want to mark a task complete, so that finished work drops off my
open list. Backend-only: a `completeTask` mutation and completion timestamp in
`api`.

**Acceptance Criteria:**

**Given** an open task **When** it is marked complete **Then** a completion
timestamp is recorded **And** the open/done filter reflects the new status.
