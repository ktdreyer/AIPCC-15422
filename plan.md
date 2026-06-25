# [AIPCC-15422](https://redhat.atlassian.net/browse/AIPCC-15422): Non-stable branches must not use non-stable image versions

## Context

Non-stable (Early Access or "fast") image versions can accidentally end up in GA (Generally Available) builds if someone manually edits a build-args conf file or if Renovate proposes a non-stable image bump on a GA branch. There is no guardrail today.

Different products use different pre-release naming conventions:
- **RHAII** uses "fast" (tags like `3.5.fast1+timestamp`)
- **Base** uses "ea" (tags like `3.4.0-ea.1-1773283875`)
- **RHEL AI** uses "ea" (same format as Base)

This plan adds a Tekton pipeline check that catches non-stable images at build time regardless of how they got there. A `stable-release` boolean parameter controls whether the check runs.

## Approach

### Layer 1: Tekton pipeline check (inline script)

The check script is inlined directly in the Tekton task's `script:` field, using `ubi9-minimal` as the step image. No external image dependency.

**[konflux-data](https://gitlab.com/redhat/rhel-ai/konflux-data)** — new `tasks/assert-all-images-are-stable.yaml` ([MR !418](https://gitlab.com/redhat/rhel-ai/konflux-data/-/merge_requests/418)):
- Self-contained — script is embedded in the task YAML
- Receives a `BUILD_ARGS_FILE` param — forwarded from the pipeline's existing `build-args-file` parameter that every PipelineRun already sets (e.g. `build-args/cuda-ubi9.conf`, `argfile-cuda.conf`)
- Greps all values for two non-stable patterns: `-ea.` (EA tags) and `-fast.` (fast tags)
- If the file is empty or not found, passes silently
- Uses `registry.access.redhat.com/ubi9-minimal:latest` — no toolbox image dependency

**Why check all values instead of specific key names?** Each container repo has different key names (`BASE_IMAGE`, `VLLM_IMAGE`, `MODEL_OPT_IMAGE`, etc.) and can add new ones at any time. Grepping for specific names like `*IMAGE*` is fragile. Checking all values is simpler and more robust — the `-ea.` pattern matches EA image tags but does not match non-image values like version IDs (`3.5-EA1` has no dot after "EA"), hostnames (`redhat.com`), or plain numbers.

**Testing:** [ShellSpec](https://shellspec.info/) tests extract the script from the task YAML at test time using `yq`, replace Tekton variable references with temp directories, and run the script against fixtures. This follows the pattern established in upstream [Konflux build-definitions](https://github.com/konflux-ci/build-definitions), specifically the [`fbc-fips-check` task](https://github.com/konflux-ci/build-definitions/tree/main/task/fbc-fips-check/0.1/spec). A generic `shellspec` CI job in `.gitlab-ci.yml` auto-discovers specs, so future tasks can add tests without CI config changes.

**[konflux-data](https://gitlab.com/redhat/rhel-ai/konflux-data)** — `pipelines/full-container.yaml` and `pipelines/disk-image-container.yaml`:
- Add `stable-release` string parameter (default `"true"`)
- Add `assert-all-images-are-stable` task that receives `SOURCE_ARTIFACT` from `clone-repository` (Trusted Artifacts pattern) and forwards `$(params.build-args-file)` — no new parameters needed per component since every PipelineRun already sets `build-args-file`
- Gated by `when: stable-release in ["true"]` only — independent of `skip-checks`, because skipping post-build checks (Snyk, Clair, etc.) should not also skip this pre-build safety gate
- Runs after `clone-repository` so it fails fast before the expensive multi-platform container build starts
- `prefetch-dependencies` has `assert-all-images-are-stable` in its `runAfter`, so a failure blocks the pipeline before the expensive build

We use `stable-release` rather than `skip-stable-check` or `allow-non-stable-images` because it describes a fact about the build ("this is a stable release") rather than a permission or action. This makes it harder to misuse as a workaround — setting `stable-release: "false"` on a GA branch would be a factual lie, not just flipping a switch.

**Why not pass `target-branch` instead of `stable-release`?** The pipeline is deliberately branch-agnostic by design: branch decisions happen at the PipelineRun trigger layer (via CEL expressions), and the pipeline only receives a commit SHA. Adding `target-branch` as a pipeline parameter would break this separation. The `stable-release` boolean lets the PipelineRun declare what kind of build this is without leaking branch semantics into the shared pipeline.

**[aipcc-product-management](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management)** — `onboard-product.py` ([MR !49](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management/-/merge_requests/49)):
- `get_extra_pipelinerun_params()` auto-injects `stable-release: "false"` when the branch name contains `-ea` or `-fast` (case-insensitive)
- This is the safety net for future non-stable branches — no manual config changes needed
- If the config already sets `stable-release` manually, the function avoids duplicating it

**[aipcc-product-management-configs](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management-configs)** — non-stable branch config files ([MR !318](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management-configs/-/merge_requests/318)):
- Add `stable-release: "false"` to the common `params` in existing EA branch configs (belt-and-suspenders with the auto-injection above)
- The existing [`extra_params` mechanism](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management/-/blob/b63baddf9d061140fa9a9afe3da26cfaa351b53e/templates/pipelinerun/full-container.yaml.j2#L99-102) in the PipelineRun Jinja template already supports this — no template changes needed
- Regenerate PipelineRun files with `onboard-product.py`

### Layer 2: Renovate rules — not needed

Investigated whether we need `allowedVersions` rules to block non-stable image versions on GA branches. Existing guards already handle it:

**[rhaiis/containers](https://gitlab.com/redhat/rhel-ai/rhaiis/containers)** — each GA branch already has per-branch `allowedVersions` patterns like `/^3\.4\.0\-[\d.]+$/`. The `[\d.]+` suffix only allows digits and dots, which naturally excludes EA tags (`-ea.` has letters) and fast tags (`.fast` has letters).

**[containers/bootc](https://gitlab.com/redhat/rhel-ai/containers/bootc)** — Renovate uses `"redhat"` versioning for RHAIIS images. The [upstream source](https://github.com/renovatebot/renovate/blob/main/lib/modules/versioning/redhat/index.ts) uses a regex that requires the release portion to be digits only: `(?:-(?<releaseMajor>\d+)(?:\.(?<releaseMinor>\d+))?)`. EA tags like `3.4.0-ea.1-1773283875` and fast tags like `3.5.fast1+timestamp` fail to parse and are silently ignored. The upstream [test suite](https://github.com/renovatebot/renovate/blob/main/lib/modules/versioning/redhat/index.spec.ts) explicitly verifies that non-numeric releases like `3.0.0-beta` are invalid, which protects this behavior.

No MRs needed for Layer 2.

### Considered alternative: toolbox container image

We considered placing the check script in the [toolbox](https://gitlab.com/redhat/rhel-ai/ci-cd/toolbox) repo ([MR !11](https://gitlab.com/redhat/rhel-ai/ci-cd/toolbox/-/merge_requests/11)) for reuse across CI systems. Adrian chose the inline approach instead for faster iteration — no cross-repo image rebuild dependency. The toolbox MR remains open if we want to revisit later.

## Files to modify

| Repo | File | Change |
|------|------|--------|
| konflux-data | `.shellspec` | ShellSpec config (establishes test framework for the repo) |
| konflux-data | `.gitlab-ci.yml` | Add `test` stage and generic `shellspec` job |
| konflux-data | `tasks/assert-all-images-are-stable.yaml` | New task definition (inline script, ubi9-minimal image) |
| konflux-data | `spec/assert_all_images_are_stable_spec.sh` | ShellSpec tests |
| konflux-data | `pipelines/full-container.yaml` | Add `stable-release` param, wire `assert-all-images-are-stable` task |
| konflux-data | `pipelines/disk-image-container.yaml` | Same |
| aipcc-product-management | `onboard-product.py` | Auto-inject `stable-release: "false"` for branches containing `-ea` or `-fast` |
| aipcc-product-management | `tests/test_unit.py` | Tests for `get_extra_pipelinerun_params` |
| aipcc-product-management-configs | Non-stable branch config files | Add `stable-release: "false"` to `params` for existing EA/fast branches |
| ~~rhaiis/containers~~ | ~~`renovate.json`~~ | ~~Not needed — existing `allowedVersions` patterns already block non-stable~~ |
| ~~containers/bootc~~ | ~~`renovate.json`~~ | ~~Not needed — `"redhat"` versioning can't parse non-stable tags~~ |

## Verification

1. **ShellSpec tests**: Run `shellspec` from the konflux-data repo root — test cases cover empty/missing files, GA values, EA values, fast values, mixed files, and false-positive cases
2. **Tekton task**: Validate YAML with `tkn task validate` or `oc apply --dry-run=client`
3. **Pipeline changes**: Validate with `tkn pipeline validate` or dry-run
4. **Live PipelineRun testing**: Create draft MRs in `rhaiis/containers` pointing `pipelineRef.revision` to the unmerged branch, covering four scenarios: stable images (pass), EA refs (fail), fast refs (fail), and `stable-release: "false"` (skip). See test plan in `drafts/aipcc-15422-testing-prompt.md`
5. **PipelineRun generation**: Run `onboard-product.py` with non-stable configs and verify `stable-release: "false"` appears in generated `.tekton/*.yaml` files; run existing tests with `uv run python -m pytest`

## Rollout order

1. Merge aipcc-product-management change: auto-inject `stable-release: "false"` for non-stable branches (safe — no effect until the pipeline declares the parameter)
2. Merge aipcc-product-management-configs: add `stable-release: "false"` to existing non-stable branch configs, then regenerate PipelineRuns (safe — Tekton ignores unknown PipelineRun params)
3. Merge konflux-data MR: task YAML, ShellSpec tests, CI job, and pipeline changes (activates the check — by this point non-stable branches already have `stable-release: "false"`)
