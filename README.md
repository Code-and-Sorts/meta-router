<img src="docs/images/banner.svg" alt="Meta Router" width="100%">

Run multiple [BMad Method](https://github.com/bmad-code-org/BMad-METHOD) projects out of one repo. One shared `_bmad/` core, one project active at a time, switched with a symlink swap.

BMad assumes one project per repo. If several projects share the same agents and workflows, you'd otherwise duplicate `_bmad/` everywhere. This keeps a single core and isolates each project's artifacts.

> Meta Router is an independent tool that builds on the BMad Method — it is not affiliated with or endorsed by the BMad project.

[Browse a live example →](https://github.com/Code-and-Sorts/meta-router/tree/example) — a generated metarepo with two projects, sample artifacts, and the worktree setup. Regenerated on every push to `main`.

## Quick start

Requirements: Node.js ≥ 20 (for BMad), git, bash.

```bash
git clone https://github.com/Code-and-Sorts/meta-router meta-router
bash meta-router/setup.sh my-metarepo
```

Setup asks four things — output folder name (default `features`), docs folder name (default `docs`), which agent tool you use (Claude Code, GitHub Copilot, or Codex), and which projects to create — then installs BMad and scaffolds everything. After that:

```bash
cd my-metarepo
bash scripts/meta-router.sh init food-inventory   # create + switch to a project
bash scripts/meta-router.sh switch camera-app     # change active project
bash scripts/meta-router.sh list                  # list projects
```

![Setup](docs/images/01-setup.png)

**Non-interactive** (CI/scripts): set `BMAD_SETUP_NONINTERACTIVE=1` and pass answers as env vars.

```bash
BMAD_SETUP_NONINTERACTIVE=1 \
  BMAD_OUTPUT_FOLDER=features BMAD_DOCS_FOLDER=docs \
  BMAD_SETUP_TOOL=claude-code BMAD_SETUP_PROJECTS=alpha,beta \
  bash meta-router/setup.sh my-metarepo
```

## What switching does

`switch <project>` repoints symlinks at the repo root and writes `active-project.txt`. BMad reads and writes through them unchanged — nothing is copied or deleted.

| Symlink | points to |
| --- | --- |
| `features/` | `projects/<project>/features/` |
| `docs/` | `projects/<project>/docs/` |
| `<tool-home>/skills/project/` | `projects/<project>/<tool-home>/skills/` |
| `repos/` | `projects/<project>/repos/` |
| `implementation/` | `projects/<project>/implementation/` |

Context comes in two tiers: **overall shared context** (`<tool-home>/knowledge/shared-context.md`) holds org-wide standards that apply to every project and is global — it does *not* change on switch; each project's **`project-context.md`** holds its own conventions and overrides the shared context on conflict. Agents read both before every workflow (BMad loads the shared one via `_bmad/custom/` `persistent_facts`).

## Layout

![File structure](docs/images/02-tree.png)

- `_bmad/` — shared BMad core (agents, workflows, tasks), installed once.
- `projects/<name>/features/` — that project's BMad output: PRD, architecture, epics, stories, sprint status, `project-context.md`.
- `projects/<name>/docs/` — that project's `project_knowledge`.
- `projects/<name>/<tool-home>/skills/` — agent skills that activate only when the project is switched in.
- `<tool-home>/skills/<name>/` — always-active skills (e.g. `router-project-switch`).
- `<tool-home>/knowledge/` — shared docs available to every project.
- `<tool-home>/knowledge/shared-context.md` — overall shared context (org-wide standards) loaded for every project, alongside each project's `project-context.md`.
- `projects/<name>/repos.yaml` — manifest of the project's source repos (tracked). Clones and worktrees are gitignored.
- `AGENTS.md` — root context file for the agent.

The `.claude` directory follows your agent tool: `.github` for Copilot, `.codex` for Codex, `.agents` as a fallback.

## Commands

```bash
bash scripts/meta-router.sh <command>
```

| Command | Does |
| --- | --- |
| `init <name>` | scaffold and switch to a new project |
| `switch <name>` | change the active project |
| `list` | list projects (active marked, with skill counts) |
| `current` | show active project and symlink targets |
| `config` | show resolved folders, agent tool, and where each came from |
| `validate` | check symlinks, `AGENTS.md`, artifact dirs |
| `repos` / `clone [repo]` | list / clone the project's source repos |
| `worktree <story> [repo...]` | create per-story git worktree(s) |
| `worktree list` / `worktree-rm <story>` | list / remove story worktrees |

![Listing and switching](docs/images/03-list-switch.png)
![Current state and config](docs/images/04-current-config.png)
![Validate](docs/images/05-validate.png)

## Configuration

Folder names and the agent tool resolve in order: **env var → `_bmad/bmm/config.yaml` → default**. Setup writes your choices into `config.yaml`, so the router picks them up afterward.

| Setting | Env var | config.yaml key | Default |
| --- | --- | --- | --- |
| Output folder | `BMAD_OUTPUT_FOLDER` | `output_folder` | `features` |
| Docs folder | `BMAD_DOCS_FOLDER` | `project_knowledge` | `docs` |
| Agent tool | `BMAD_AGENT_TOOL` | `agent_tool` | `claude-code` |

The agent tool sets where skills and shared knowledge live: `.claude/` (Claude Code), `.github/` (Copilot), `.codex/` (Codex). Setup also points BMad's `planning_artifacts` / `implementation_artifacts` at your output folder.

## Source repos and worktrees

The metarepo tracks planning artifacts, not source. Each project lists its repos in `repos.yaml`:

```yaml
repos:
  - name: web
    url: git@github.com:you/web.git
    branch: main
  - name: api
    url: git@github.com:you/api.git
    branch: main
```

```bash
bash scripts/meta-router.sh clone                                  # clone all (or: clone web)
bash scripts/meta-router.sh worktree 1-2-account-management web api  # one worktree per repo
bash scripts/meta-router.sh worktree 1-2-account-management --all    # every repo
bash scripts/meta-router.sh worktree-rm 1-2-account-management      # tear down
```

Worktrees land at `projects/<name>/implementation/<story-id>/<repo>/` (gitignored), each on branch `story/<story-id>`. The story id is the story's `development_status` key from `sprint-status.yaml` — the GitHub sync keys PR detection off that branch name. A full-stack story can span several repos at once.

Setup wires this into BMad through `_bmad/custom/`: the scrum master adds an `## Affected Repos` section to each story, and the dev agent reads it to create the worktrees before implementing. See `_bmad/custom/worktree-workflow.md`.

## GitHub Issues + Projects sync (optional)

Optional layer that mirrors each project's BMad artifacts to GitHub. Enable it during setup (or copy `templates/.github` in later). Each project gets a **private GitHub Project board** and two label-separated issue trees:

- **Delivery** (`bmad-delivery`): a `Delivery` root → **Feature issues (one per PRD)** → Epic issues → Story sub-issues. Epics/stories are driven by the `development_status:` map in `sprint-status.yaml`; features come from the PRD run folders (`prds/prd-*/prd.md`), with the newest PRD holding the epics (BMad generates `epics.md` from it). Native sub-issue progress bars give per-epic and per-feature rollups for free; superseded PRDs close automatically. Issues are created in the metarepo by default; set `repo:` in a project's `github-sync.yaml` to keep its issues next to the code instead.
- **Planning** (`bmad-planning`, always in the metarepo): one `Planning: <project>` checklist issue tracking which planning artifacts (brief, PRD, UX, architecture, epics) exist — the PM/architect view, separate from the engineering board.

The sync is the single writer of issue state and board Status: BMad statuses map to `Backlog / Ready / In Progress / In Review / Done`, an open PR on a `story/<story-key>` branch in any `repos.yaml` repo forces `In Review`, and `done` closes the issue. Story PRs (one per affected repo) are linked onto the story issue automatically — a maintained **Pull Requests** section lists each PR with its repo and state (open/merged/closed). Stories that vanish after renumbering are closed as not-planned with a `bmad-orphaned` label, never deleted. Sync is idempotent — each issue carries a hidden `<!-- bmad-sync:key:project -->` marker, so re-runs update rather than duplicate.

Setup, per project:

1. Push the metarepo to GitHub (issues live there by default; optionally set `repo:` in `projects/<name>/github-sync.yaml` to use the project's source repo — any org or personal account works). Boards can live under any owner too: the bootstrap asks where (saveable as `project_owner:` in the metarepo-root `github-sync.yaml`, overridable per project).
2. `bash scripts/bmad-github-bootstrap.sh <name>` — creates the private board, labels, and org issue types. On first run it offers to set up an org project template (name it whatever you like; the default is "BMad Project Template"): you build the views (Backlog, Epic Progress, Features, Planning — GitHub has no API for views) exactly once and every future board is copied from the template with views included. Views are visual-only: the script warns if the Backlog view is missing but never blocks on them — add or change them anytime. The chosen name is saved as `template:` in a metarepo-root `github-sync.yaml` (override per run with `BMAD_TEMPLATE_NAME`), alongside an auto-managed `template_id:` — lookups go by that immutable ID first, so renaming the template later can't break the flow. Without a template (or on user accounts, where templates aren't supported) each board gets a printed view checklist instead.
3. Add a `BMAD_PROJECT_TOKEN` secret: PAT with **Projects read/write** + **Issues read/write** + **Pull requests read**. The default `GITHUB_TOKEN` cannot access Projects v2. If everything lives under one org, a fine-grained PAT works; if repos/boards span multiple orgs or your personal account, use a classic PAT (`project` + `repo` scopes — fine-grained PATs are single-owner) or a GitHub App installed per org.
4. Install `templates/bmad-pr-ping.yml` into each source repo so story PRs update the board immediately (the nightly reconcile covers anything missed)

Run locally with `python scripts/bmad-issues.py sync --dry-run` (needs `gh` authenticated).

## Notes

- **Symlinks on Windows** need `core.symlinks=true` (WSL works out of the box).
- **All symlinks move together** — no split-brain where output and docs point at different projects.
- **Source is gitignored** — clones (`projects/*/repos/`) and worktrees (`projects/*/implementation/`) aren't tracked; remove those `.gitignore` lines if you want them in.
- **One BMad version** for all projects, since they share `_bmad/`.
- **Default output folder is `features`, not BMad's `_bmad-output`** — reads better in a metarepo. Change it during setup or in `config.yaml`.

## Tests

```bash
pip install pytest pyyaml
pytest tests/ -v
```

Router tests in `tests/test_bmad_router.py`, issue-sync tests in `tests/test_bmad_issues.py`. These cover this repo; generated metarepos ship only a shellcheck CI workflow, not the test suite.

## File manifest

```markdown
meta-router/
├── setup.sh                        # Bootstrap a new metarepo
├── scripts/
│   ├── meta-router.sh              # Context switcher (copied into metarepo)
│   └── bmad-issues.py              # GitHub Issues sync (optional)
├── templates/
│   ├── .github/workflows/
│   │   ├── ci.yml                  # Metarepo CI (shellcheck), installed into each metarepo
│   │   └── sync-issues.yml         # GitHub Action (optional)
│   ├── bmad-custom/                # BMad overrides → _bmad/custom/
│   │   ├── bmad-dev-story.toml     #   create per-story worktrees on implement
│   │   ├── bmad-create-story.toml  #   add "## Affected Repos" to stories
│   │   └── worktree-workflow.md    #   the worktree procedure (loaded as context)
│   └── github-sync.yaml            # Per-project sync config template
├── examples/seed/                  # Seed content overlaid onto the example branch
├── .github/workflows/
│   ├── ci.yml                      # pytest + shellcheck (this repo)
│   └── generate-example.yml        # Publishes the example branch on push to main
├── SKILL.md                        # Agent skill definition
├── tests/                          # Router + issue-sync test suites
└── docs/images/                    # README screenshots
```
