# [AIPCC-15422](https://redhat.atlassian.net/browse/AIPCC-15422): Non-stable branches must not use non-stable image versions

## Context

Non-stable (Early Access or "fast") image versions can accidentally end up in GA builds if someone manually edits a build-args conf file or if Renovate proposes a non-stable image bump on a GA branch. There is no guardrail today for RHAIIS.

Different products use different pre-release naming conventions:
- **RHAIIS** uses "fast" (tags like `3.5.fast1+timestamp`)
- **Base** uses "ea" (tags like `3.4.0-ea.1-1773283875`)
- **RHEL AI** uses "ea" (same format as Base)

This plan adds a centralized check script in the [toolbox](https://gitlab.com/redhat/rhel-ai/ci-cd/toolbox) repo, delivered via a GitLab CI template that product repos include.

### Why GitLab CI instead of Tekton

The [prior approach](https://github.com/ktdreyer/AIPCC-15422/blob/main/plan.md) used a Tekton task in the shared Konflux pipeline. Vic [pointed out](https://redhat.atlassian.net/browse/AIPCC-15422) that checks like this are easier to maintain in GitLab CI than Tekton:

- Tekton/Konflux pipelines require Trusted Artifacts, cross-repo parameter plumbing, and multi-MR rollout ordering
- bootc already solved the same problem with [`ci-scripts/check-bib-versions.sh`](https://gitlab.com/redhat/rhel-ai/containers/bootc/-/blob/main/ci-scripts/check-bib-versions.sh) — a standalone script called from `.gitlab-ci.yml`
- The `main` branch regularly carries EA images during development, making a pipeline-level `stable-release` toggle churn-prone

### Why centralized in toolbox

A centralized script in toolbox covers the generic check (no EA/fast markers in stable builds) across all product repos. Product-specific consistency checks (namespace validation, cross-file version agreement, Konflux artifact references) stay in per-repo `ci-scripts/` where they belong.

The [toolbox](https://gitlab.com/redhat/rhel-ai/ci-cd/toolbox) repo already ships shared CI scripts via a container image (`quay.io/aipcc-cicd/toolbox`) and has a `templates/` directory for GitLab CI includes (see `templates/vault.yml`).

### Why the script reads the version key instead of a pipeline parameter

The `main` branch regularly carries EA images during development (e.g. spyre at `3.5-EA1` while others are at `3.4.0`). A branch-level `stable-release` parameter would need to toggle on every EA/GA transition — churn with no safety benefit.

Instead, the script reads a version key (e.g. `RHAIIS_VERSION` or `RHELAI_VERSION_ID`) from each conf file individually. If the value contains `-EA` or `-fast`, that file's EA/fast image refs are expected. This is the same approach bootc uses in `check-bib-versions.sh`.

## Approach

### Stack

| Layer | Repo | What |
|-------|------|------|
| Script + tests | [`ci-cd/toolbox`](https://gitlab.com/redhat/rhel-ai/ci-cd/toolbox) | `scripts/check-build-args.sh` + `tests/` |
| Image | `quay.io/aipcc-cicd/toolbox` | Ships the script (auto-included via existing Containerfile `COPY scripts/*.sh`) |
| Template | `ci-cd/toolbox` | `templates/build-args-checks.yml` — thin YAML, calls the script from the image |
| Product repos | e.g. `rhaiis/containers` | `include:` in `.gitlab-ci.yml` with inputs for file glob and version key |

### Script: `check-build-args.sh`

Lives in `toolbox/scripts/`. Receives conf file paths as arguments.

**Inputs:**
- Positional args: paths to conf files (e.g. `build-args/*.conf`)
- `VERSION_KEY` env var: key name that identifies container build configs and provides branch-awareness (e.g. `RHAIIS_VERSION`, `RHELAI_VERSION_ID`)

**Behavior:**
1. For each conf file, read the `VERSION_KEY` value. If the key is missing, skip the file — it is not a container build config (e.g. disk image or cloud image argfiles that reference already-built artifacts by digest).
2. If the version value contains `-EA` or `-fast` (case-insensitive), skip the check for that file — EA/fast image refs are expected in EA/fast builds.
3. Otherwise, grep all `KEY=VALUE` lines for `-ea.` and `-fast.` patterns (case-insensitive).
4. Exit 1 if any stable file has non-stable image refs, exit 0 otherwise.

If `VERSION_KEY` is unset, all files are checked unconditionally (no skipping).

**Why check all values instead of specific key names?** Each container repo has different key names (`BASE_IMAGE`, `VLLM_IMAGE`, `MODEL_OPT_IMAGE`, etc.) and can add new ones at any time. Checking all values is simpler — the `-ea.` pattern matches EA image tags but does not match non-image values like version IDs (`3.5-EA1` has no dot after "EA").

Draft script: [`check-build-args.sh`](check-build-args.sh) in this directory.

### Template: `build-args-checks.yml`

Lives in `toolbox/templates/`. Product repos include it with two inputs:

```yaml
include:
  - project: 'redhat/rhel-ai/ci-cd/toolbox'
    file: 'templates/build-args-checks.yml'
    inputs:
      BUILD_ARGS_GLOB: "build-args/*.conf"
      VERSION_KEY: "RHAIIS_VERSION"
```

The template defines a single job in the `checks` stage (product repos must define a `checks` stage). It uses the toolbox container image and calls `check-build-args.sh` with the expanded glob.

Draft template: [`build-args-checks.yml`](build-args-checks.yml) in this directory.

### Tests

Plain bash test runner following the pattern from [toolbox MR !11](https://gitlab.com/redhat/rhel-ai/ci-cd/toolbox/-/merge_requests/11). Tests and fixture conf files exercise:

- GA builds with stable image refs (pass)
- GA builds with EA image refs (fail)
- GA builds with fast image refs (fail)
- EA builds with EA image refs (pass — expected)
- Fast builds with fast image refs (pass — expected)
- Version key without dot (e.g. `3.5-EA1`) not triggering false positives
- Empty and missing files (pass)
- No arguments (fail with usage)

Draft tests: [`tests/`](tests/) in this directory.

### What stays per-repo

The centralized check handles the generic "no EA/fast in stable builds" policy. Product-specific checks stay in per-repo scripts:

- **bootc**: `ci-scripts/check-bib-versions.sh` — namespace consistency (`rhelai3` vs `rhelai-early-access`), version alignment across `bib-*.yaml` and `config/*.toml`, Konflux artifact references
- **RHAIIS**: future `ci-scripts/check-rhaiis-versions.sh` if product-specific invariants emerge

### Renovate rules — not needed

Investigated whether we need `allowedVersions` rules to block non-stable image versions on GA branches. Existing guards already handle it:

**[rhaiis/containers](https://gitlab.com/redhat/rhel-ai/rhaiis/containers)** — each GA branch already has per-branch `allowedVersions` patterns like `/^3\.4\.0\-[\d.]+$/`. The `[\d.]+` suffix only allows digits and dots, which naturally excludes EA tags (`-ea.` has letters) and fast tags (`.fast` has letters).

**[containers/bootc](https://gitlab.com/redhat/rhel-ai/containers/bootc)** — Renovate uses `"redhat"` versioning for RHAIIS images. The [upstream source](https://github.com/renovatebot/renovate/blob/main/lib/modules/versioning/redhat/index.ts) requires the release portion to be digits only. EA and fast tags fail to parse and are silently ignored.

### Considered alternative: Tekton pipeline task

The [prior plan](https://github.com/ktdreyer/AIPCC-15422/blob/main/plan.md) used an inline Tekton task in the shared Konflux pipeline. Three MRs were open:

- [konflux-data MR !418](https://gitlab.com/redhat/rhel-ai/konflux-data/-/merge_requests/418) — task YAML, ShellSpec tests, pipeline wiring
- [aipcc-product-management MR !49](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management/-/merge_requests/49) — auto-inject `stable-release: "false"`
- [aipcc-product-management-configs MR !318](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management-configs/-/merge_requests/318) — existing EA branch configs

These should be closed when the GitLab CI approach merges.

## Files to modify

| Repo | File | Change |
|------|------|--------|
| toolbox | `scripts/check-build-args.sh` | New script |
| toolbox | `tests/test-check-build-args.sh` | New test runner |
| toolbox | `tests/fixtures/check-build-args/*.conf` | New test fixtures |
| toolbox | `templates/build-args-checks.yml` | New GitLab CI template |
| toolbox | `.gitlab-ci.yml` | Add test stage and job |
| rhaiis/containers | `.gitlab-ci.yml` | Add `include:` for `build-args-checks.yml` |
| containers/bootc | `.gitlab-ci.yml` | Add `include:` for `build-args-checks.yml` (complements existing `check-bib-versions.sh`) |
| ~~konflux-data~~ | ~~pipelines/*.yaml~~ | ~~Close MR !418~~ |
| ~~aipcc-product-management~~ | ~~onboard-product.py~~ | ~~Close MR !49~~ |
| ~~aipcc-product-management-configs~~ | ~~config files~~ | ~~Close MR !318~~ |

## Rollout order

1. Merge toolbox MR (script, tests, template, CI) — safe, no product repos use it yet
2. Add `include:` to RHAIIS `.gitlab-ci.yml`
3. Add `include:` to bootc `.gitlab-ci.yml`
4. Close the three Tekton MRs

## Verification

1. **Unit tests**: Run `tests/test-check-build-args.sh` from the toolbox repo — covers all fixture scenarios
2. **RHAIIS live test**: Open a draft MR in `rhaiis/containers` adding the `include:` — verify check passes on `main` (spyre's `3.5-EA1` version key should cause the script to skip that file)
3. **bootc live test**: Open a draft MR in `containers/bootc` adding the `include:` — verify check passes alongside existing `check-bib-versions.sh`
