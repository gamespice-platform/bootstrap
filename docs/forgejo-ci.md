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

Locked tags: for every tag in `gs-server-deploy/addons.lock` (override the path with `FORGEJO_PINS_LOCK`) the mirror also fetches the tag's commit over SSH and pushes it as the branch `pin/<tag>` (with the injected CI commit on top), so `addons-lock.sh check-ci` finds a Forgejo run for the exact commit and makes no GitHub call. A tag that sits at the default branch's tip needs no pin branch; branches of tags that left the lock are pruned. Re-run the mirror after `addons-lock.sh write`.

A stale Forgejo copy (for example from before the dot-to-gs rename) can make the owner pre-push hook (`/usr/local/lib/git-owner-hooks`, efficiency gates on every push of `main`, compared with the remote's old tip) refuse GitHub's own tip as "baseline raised or added", because every renamed baseline key looks new. The mirror then deletes and recreates that Forgejo repo (a disposable copy) and pushes again; a first push has no old tip. The hook is not bypassed.

Tags are never pushed, on purpose: release workflows trigger on `v*` tags and must stay on GitHub. A branch push is what triggers Forgejo workflows. GitHub stays the source of truth; Forgejo is overwritten from it, so never push to Forgejo directly.

- Repos are the rows of `projects.tsv` plus `ci/forgejo-extra.tsv` (tmc-app, website-city, bootstrap: repos that are not in the project list).
- Add a repo: add a row (project list or the extra file), then `tools/forgejo-mirror.sh <name>`.
- Keep it fresh: `tools/forgejo-mirror.sh` is idempotent; run it from cron or after a push (`sudo -u gamedev tools/forgejo-mirror.sh <name>`). `--list` prints the mapping.

## Workflows

Forgejo reads `.github/workflows`, and prefers `.forgejo/workflows` when that directory exists. So a repo needs an override only where its GitHub workflow cannot run on the host runner:

- it calls a reusable workflow in a private GitHub repo (`gamespice-platform/ci/...@v1`: every Godot repo and gs-bootstrap do; the runner has no GitHub credential, by design) - such repos show no Forgejo runs until the override exists or the `ci` repo is mirrored and referenced by URL;
- it needs `sudo`, Windows, macOS, Docker, or a secret that exists only on GitHub (`PACKAGES_TOKEN`, `TMC_CLI_TOKEN`, signing keys).

Today: gs-bootstrap (`.forgejo/workflows/ci.yml`: shell and python parse, project list, unit tests) and tmc-app (`.forgejo/workflows/ci.yml` on branch `nightly/internal-ci-forgejo-1`: `tmc-core` clippy and tests, the Windows cross-check; `web` only when repo variable `PACKAGES_ENABLED=true` and secret `PACKAGES_TOKEN` are set in Forgejo). website-city only has the Images workflow (GHCR push), which stays on GitHub.

## Mirrors, public repos and the injected overrides

`tools/forgejo-mirror.sh` creates the orgs and repos as public inside Forgejo (127.0.0.1 only, sign-in required to reach it), so the job token can read sibling repos such as `gamespice-platform/ci`. It pushes from a bare cache, never tags. Before each push `tools/forgejo-inject-ci.sh` adds one commit to the cache only (never GitHub) with `.forgejo/workflows`, built by `tools/forgejo-ci-override.py`:

- a repo that calls the private reusable `gamespice-platform/ci` validate.yml gets it flattened into `ci.yml` (Forgejo rejects `workflow_call` with `secrets`): inputs resolved, Godot runtime/profile/perf steps, `actions/cache` and `apt-get` dropped, `ci` checked out from the Forgejo copy at `main`;
- any other non-release workflow that uses setup-python or apt-get gets the same workflow with those steps removed (the host runner has no toolcache and no sudo), `on:` kept valid, and `ref: main` added to sibling checkouts (Forgejo's checkout cannot look up a default branch);
- the tracked-absolute-symlink check runs but does not fail the run (`continue-on-error`): those are dev-box addon links; untracking them would delete them from every checkout on pull. The real fix is per repo and stays on the board.

Fast checks only; suites run through heavy/hv. Install `shellcheck` on the box (done). Runner capacity is 2, so a burst of pushes queues; read results after `select count(*) from action_run where status in (5,6)` is 0.

Genuinely red on source, not on the mechanism: game-template (stale `addons.lock`), profiler (JS eval at `gs_profiler_perf_report.gd:180`), server (comments/logging baselines), tmc-app (`web` needs `PACKAGES_TOKEN`, `tmc-core` rustfmt diff in `library.rs`, `gamespice-app` needs apt packages the runner cannot install).

## Reading results

`tools/ci-red-forgejo.sh` reads slugs on stdin and prints `slug<TAB>green|red|cancelled|running|none|absent`. `tools/ci-red.sh` (and nightly's `chk-ci-red.sh`) use it first. Only repos with no Forgejo run (`none`) or not mirrored (`absent`) fall back to GitHub, cached `CI_RED_GH_TTL` seconds (default 900); `CI_RED_GITHUB` now defaults to 0 (no GitHub call at all; set 1 to allow the fallback). Do not poll `gh run`: read this.

The UI/API: `http://127.0.0.1:3300/<owner>/<repo>/actions`; `GET /api/v1/repos/<owner>/<repo>/actions/tasks`.

## What stays on GitHub

Windows and macOS installer builds, Android and iOS, signing and notarisation, GHCR image pushes, every tag-triggered release, and anything using a GitHub-only secret. They need runner machines this VM is not (a Windows box and a Mac registered as extra Forgejo runners would let them move; that is an owner decision).

## Operating

`systemctl status forgejo forgejo-runner`; logs `journalctl -u forgejo-runner`; Forgejo logs in `/srv/forgejo/log`. Re-register the runner: `forgejo actions generate-runner-token` as the forgejo user, then `forgejo-runner register` in `/srv/fjrunner`. Upgrade: replace the binary in `/usr/local/bin` and restart.
