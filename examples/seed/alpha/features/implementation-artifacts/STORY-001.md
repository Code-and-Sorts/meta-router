# Story 1.1: Create a task (full-stack)

Status: ready-for-dev

> Example artifact for the bmad-router `example` branch. The **Affected Repos**
> section below is what the `bmad-dev-story` customization reads to decide how
> many git worktrees to create — here, two.

## Story

As a user, I want to create a task with a title and optional assignee, so that my
work is tracked from one place.

## Acceptance Criteria

1. The web app shows a "New task" form with a title field and assignee picker.
2. Submitting the form calls the `createTask` GraphQL mutation.
3. `createTask` validates input with zod and persists the task.
4. The new task appears in the open list without a page reload.

## Affected Repos

- web
- api

## Tasks / Subtasks

- [ ] (AC: 3) Add `createTask` mutation + zod schema in `api`.
- [ ] (AC: 1, 2) Build the New task form in `web` and wire the mutation.
- [ ] (AC: 4) Optimistically insert the created task into the open list.

## Dev Notes

This is a full-stack story. When implemented, bmad-router creates a worktree per
affected repo:

```
projects/alpha/implementation/STORY-001/web/   # branch story/STORY-001
projects/alpha/implementation/STORY-001/api/   # branch story/STORY-001
```

Implement the web and api changes in their respective worktrees and open one PR
per repo off the shared `story/STORY-001` branch.

### Source tree components to touch

- `api`: GraphQL resolvers, zod schemas, task model.
- `web`: task creation form component, GraphQL client hooks, open-list view.
