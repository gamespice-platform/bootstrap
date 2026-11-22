The internal CI: a Forgejo instance with one Actions runner on the dev VM (x-tmc-dev01). It exists so that "is CI red" and fast checks stop costing GitHub API quota (the shared `core` gh login is limited to 5000 requests an hour, and the sweep used 2-3 per repo).

## What runs

| Part | Where | Notes |
| --- | --- | --- |
| Forgejo 17 | `forgejo.service`, `127.0.0.1:3300` | SQLite, data in `/srv/forgejo`, config `/srv/forgejo/custom/conf/app.ini`, memory cap 1G. Localhost only, sign-in required, registration off, SSH off. Actions on, default actions URL `https://github.com` so `actions/checkout@v4` resolves |
| forgejo-runner 13 | `forgejo-runner.service`, user `fjrunner`, `/srv/fjrunner` | Host executor (no docker: 3 GB of RAM headroom), capacity 2, job timeout 1 h, memory cap 6G, nice 10. Labels `ubuntu-latest`, `ubuntu-22.04`, `linux`, all `:host` |
| Credentials | `~/.config/forgejo/env` (gamedev, mode 600, admin token), `readonly.env` (gamedev and core, read-only token) | Never print or commit them |

The binaries are in `/usr/local/bin`. Both services are enabled at boot. Anything memory-hungry that a workflow starts shares the VM with the fleet: keep Forgejo workflows to the fast checks.

Not exposed: there is no nginx, DNS or auth in front of it. To read the UI from a browser, tunnel: `ssh -L 3300:127.0.0.1:3300 <vm>`, sign in as `ci-admin` (password in `~/.config/forgejo/env`, gamedev only). Publishing it under tmcdev.net behind the usual auth is an owner step.

## How repositories get there

`tools/forgejo-mirror.sh` (run as gamedev: it uses that user's GitHub SSH key, and never touches the GitHub API or the gh token):

1. creates the org (the GitHub owner) and a private repo when missing, enables Actions;
2. fetches the GitHub branches over SSH into a bare cache (`~/.cache/forgejo-mirror`);
3. pushes the branches to Forgejo and sets the default branch to GitHub's.

Tags are never pushed, on purpose: release workflows trigger on `v*` tags and must stay on GitHub. A branch push is what triggers Forgejo workflows. GitHub stays the source of truth; Forgejo is overwritten from it, so never push to Forgejo directly.

- Repos are the rows of `projects.tsv` plus `ci/forgejo-extra.tsv` (tmc-app, website-city, bootstrap: repos that are not in the project list).
- Add a repo: add a row (project list or the extra file), then `tools/forgejo-mirror.sh <name>`.
- Keep it fresh: `tools/forgejo-mirror.sh` is idempotent; run it from cron or after a push (`sudo -u gamedev tools/forgejo-mirror.sh <name>`). `--list` prints the mapping.

## Workflows

Forgejo reads `.github/workflows`, and prefers `.forgejo/workflows` when that directory exists. So a repo needs an override only where its GitHub workflow cannot run on the host runner:

- it calls a reusable workflow in a private GitHub repo (`gamespice-platform/ci/...@v1`: every Godot repo and dot-bootstrap do; the runner has no GitHub credential, by design) - such repos show no Forgejo runs until the override exists or the `ci` repo is mirrored and referenced by URL;
- it needs `sudo`, Windows, macOS, Docker, or a secret that exists only on GitHub (`PACKAGES_TOKEN`, `TMC_CLI_TOKEN`, signing keys).

Today: dot-bootstrap (`.forgejo/workflows/ci.yml`: shell and python parse, project list, unit tests) and tmc-app (`.forgejo/workflows/ci.yml` on branch `nightly/internal-ci-forgejo-1`: `tmc-core` clippy and tests, the Windows cross-check; `web` only when repo variable `PACKAGES_ENABLED=true` and secret `PACKAGES_TOKEN` are set in Forgejo). website-city only has the Images workflow (GHCR push), which stays on GitHub.

## Reading results

`tools/ci-red-forgejo.sh` reads slugs on stdin and prints `slug<TAB>green|red|cancelled|running|none|absent`. `tools/ci-red.sh` (and nightly's `chk-ci-red.sh`) use it first. Only repos with no Forgejo run (`none`) or not mirrored (`absent`) fall back to GitHub, cached `CI_RED_GH_TTL` seconds (default 900); `CI_RED_GITHUB=0` forbids any GitHub call. Do not poll `gh run`: read this.

The UI/API: `http://127.0.0.1:3300/<owner>/<repo>/actions`; `GET /api/v1/repos/<owner>/<repo>/actions/tasks`.

## What stays on GitHub

Windows and macOS installer builds, Android and iOS, signing and notarisation, GHCR image pushes, every tag-triggered release, and anything using a GitHub-only secret. They need runner machines this VM is not (a Windows box and a Mac registered as extra Forgejo runners would let them move; that is an owner decision).

## Operating

`systemctl status forgejo forgejo-runner`; logs `journalctl -u forgejo-runner`; Forgejo logs in `/srv/forgejo/log`. Re-register the runner: `forgejo actions generate-runner-token` as the forgejo user, then `forgejo-runner register` in `/srv/fjrunner`. Upgrade: replace the binary in `/usr/local/bin` and restart.
