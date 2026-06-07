# Contributing to Meta Router

## Prerequisites

- Node.js ≥ 20 (required by BMad)
- Python 3.11+
- git
- [shellcheck](https://www.shellcheck.net/) (`brew install shellcheck` on macOS)

## Running the tests

```bash
pip install pytest pyyaml
pytest tests/ -v
```

`tests/test_bmad_router.py` covers the context switcher; `tests/test_bmad_issues.py` covers the GitHub Issues sync. The test suite lives only in this repo — generated metarepos ship a shellcheck-only CI workflow, not these tests.

## Linting

```bash
shellcheck setup.sh skills/meta-router/scripts/*.sh
gh skill publish --dry-run
```

Fix any warnings before opening a PR. The CI in `.github/workflows/ci.yml` runs `pytest`, `shellcheck`, and the `gh skill` format validation on every push and pull request.

## Pull request expectations

- Tests pass (`pytest tests/ -v`) and shellcheck is clean.
- Keep changes focused — one concern per PR.
- If you add a new `meta-router.sh` command, update the Commands table in `docs/reference.md`.
- If you change setup behaviour, verify the non-interactive path still works (see the `BMAD_SETUP_NONINTERACTIVE` env vars documented in `docs/reference.md`).

## Reporting issues

Use the GitHub issue templates: **Bug report** for unexpected behaviour, **Feature request** for new ideas.
