# [AIPCC-15422](https://redhat.atlassian.net/browse/AIPCC-15422): Non-EA branches must not use EA image versions

## Context

EA (Early Access) image versions can accidentally end up in GA (Generally Available) builds if someone manually edits a build-args conf file or if Renovate proposes an EA image bump on a GA branch. There is no guardrail today. This plan adds two complementary layers: a Renovate rule to prevent EA bumps from being proposed, and a Tekton pipeline check to catch EA images at build time regardless of how they got there.

## Approach

### Why two layers?

Renovate rules are preventive — they stop bad merge requests from being opened. But they only cover automated dependency bumps. A developer could manually edit a conf file and introduce an EA image reference. The pipeline check catches everything at build time regardless of how the EA reference got there. Neither layer alone is sufficient.

### Layer 1: Tekton pipeline check (3 repos)

**[toolbox](https://gitlab.com/redhat/rhel-ai/ci-cd/toolbox)** — new `scripts/assert-no-ea-build-args.sh`:
- A generic script that accepts one or more conf file paths as arguments
- Parses all `KEY=VALUE` lines (skipping comments and blanks)
- Checks all values for the `-ea.` pattern (case-insensitive) — no need to hard-code which keys contain images
- Exits 0 if no EA references found, exits 1 with a listing of which keys matched
- Ships in the [toolbox container image](https://gitlab.com/redhat/rhel-ai/ci-cd/toolbox/-/blob/main/Containerfile) automatically via the existing `COPY --chmod=755 scripts/*.sh /opt/toolbox/scripts/` and `$PATH` setup

**Why check all values instead of specific key names?** Each container repo has different key names (`BASE_IMAGE`, `VLLM_IMAGE`, `MODEL_OPT_IMAGE`, etc.) and can add new ones at any time. Grepping for specific names like `*IMAGE*` is fragile. Checking all values is simpler and more robust — the `-ea.` pattern matches EA image tags (e.g. `3.4.0-ea.1-1777444689`) but does not match non-image values like version IDs (`3.5-EA1` has no dot after "EA"), hostnames (`redhat.com`), or plain numbers.

**Why toolbox instead of per-repo scripts?** [Team feedback](https://gitlab.com/redhat/rhel-ai/containers/bootc/-/merge_requests/409#note_2596100037): CI helper scripts should live in a centralized, CI-focused repo so they're maintained in one place and work across any CI system (Tekton, GitLab CI, GitHub Actions). The toolbox image is already used for CI utilities and bakes scripts into `$PATH`. This avoids duplicating the same logic across rhaiis/containers and containers/bootc.

**[konflux-data](https://gitlab.com/redhat/rhel-ai/konflux-data)** — new [`tasks/check-ea-images.yaml`](check-ea-images-task.yaml):
- Uses the toolbox container image
- Receives a `BUILD_ARGS_FILE` param — forwarded from the pipeline's existing `build-args-file` parameter that every PipelineRun already sets (e.g. `build-args/cuda-ubi9.conf`, `argfile-cuda.conf`)
- Runs `assert-no-ea-build-args.sh` against that file
- If the file is empty or not found, passes silently

**[konflux-data](https://gitlab.com/redhat/rhel-ai/konflux-data)** — `pipelines/full-container.yaml` and `pipelines/disk-image-container.yaml` ([snippet](pipeline-snippet.yaml)):
- Add `ea-build` string parameter (default `"false"`)
- Add `check-ea-images` task that forwards the existing `$(params.build-args-file)` to the task — no new parameters needed per component since every PipelineRun already sets `build-args-file`
- Gated by `when: ea-build in ["false"]` and `skip-checks in ["false"]` (same style as the existing [`deprecated-base-image-check`](https://gitlab.com/redhat/rhel-ai/konflux-data/-/blob/a029a2edeb91523e985b1c0fd1a4ece5b597c75f/pipelines/full-container.yaml#L375-396) task)
- Runs after `clone-repository` so it fails fast before the expensive multi-platform container build starts

We use `ea-build` rather than `skip-ea-check` or `allow-ea-images` because it describes a fact about the build ("this is an EA build") rather than a permission or action. This makes it harder to misuse as a workaround — setting `ea-build: "true"` on a GA branch would be a factual lie, not just flipping a switch.

**[aipcc-product-management-configs](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management-configs)** — EA branch config files:
- Add `extra_params: [{name: ea-build, value: "true"}]` to EA branch product configs
- The existing [`extra_params` mechanism](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management/-/blob/b63baddf9d061140fa9a9afe3da26cfaa351b53e/templates/pipelinerun/full-container.yaml.j2#L99-102) in the PipelineRun Jinja template already supports this — no template changes needed
- Regenerate PipelineRun files with `onboard-product.py`

**Why not pass `target-branch` instead of `ea-build`?** The pipeline is deliberately branch-agnostic by design: branch decisions happen at the PipelineRun trigger layer (via CEL expressions), and the pipeline only receives a commit SHA. Adding `target-branch` as a pipeline parameter would break this separation. The `ea-build` boolean lets the PipelineRun declare what kind of build this is without leaking branch semantics into the shared pipeline.

### Layer 2: Renovate rules (2 repos)

**[rhaiis/containers](https://gitlab.com/redhat/rhel-ai/rhaiis/containers)** — [`renovate.json`](https://gitlab.com/redhat/rhel-ai/rhaiis/containers/-/blob/f9e768a501322e57a3d6880b7784c2d6e22a18b4/renovate.json):
- Add packageRule blocking EA versions on GA branches:
  ```json
  {
    "description": "Block EA image versions on non-EA branches",
    "matchPackageNames": ["/^quay\\.io\\/aipcc\\//"],
    "matchBaseBranches": ["main", "3.0", "3.1", "3.2"],
    "allowedVersions": "/^(?!.*-ea\\.).*$/"
  }
  ```

**[containers/bootc](https://gitlab.com/redhat/rhel-ai/containers/bootc)** — [`renovate.json`](https://gitlab.com/redhat/rhel-ai/containers/bootc/-/blob/26934ab380776e843bdf6c95a5a52c9e952bd5d5/renovate.json):
- Add equivalent packageRule:
  ```json
  {
    "description": "Block EA image versions on non-EA branches",
    "matchPackageNames": ["quay.io/aipcc/rhaiis/**", "quay.io/aipcc/rhaiis-model-opt/**"],
    "matchBaseBranches": ["/^main$|^\\d+\\.\\d+$/"],
    "allowedVersions": "/^(?!.*-ea\\.).*$/"
  }
  ```
- Uses regex for `matchBaseBranches` to match the existing `baseBranchPatterns` style in this repo (bootc uses regex patterns rather than explicit branch lists, so the Renovate rule follows suit)

## Files to modify

| Repo | File | Change |
|------|------|--------|
| toolbox | `scripts/assert-no-ea-build-args.sh` | New script |
| konflux-data | `tasks/check-ea-images.yaml` | New task definition (uses toolbox image) |
| konflux-data | `pipelines/full-container.yaml` | Add `ea-build` param, wire `check-ea-images` task with existing `build-args-file` |
| konflux-data | `pipelines/disk-image-container.yaml` | Same |
| aipcc-product-management-configs | EA branch config files | Add `extra_params` for `ea-build` |
| rhaiis/containers | `renovate.json` | Add EA blocking packageRule |
| containers/bootc | `renovate.json` | Add EA blocking packageRule |

## Verification

1. **assert-no-ea-build-args.sh**: Test locally against current conf files in both repos — should pass on GA values, should catch `-ea.` patterns in test data
2. **Tekton task**: Validate YAML with `tkn task validate` or `oc apply --dry-run=client`
3. **Pipeline changes**: Validate with `tkn pipeline validate` or dry-run
4. **Renovate rules**: Test regex patterns against known EA version strings (e.g. `3.4.0-ea.1-1777444689` should be blocked, `3.4.0-1777444689` should pass)
5. **PipelineRun generation**: Run `onboard-product.py` with EA configs and verify `ea-build: "true"` appears in generated `.tekton/*.yaml` files; run existing tests with `uv run python -m pytest`

## Rollout order

This order ensures the toolbox image is ready before the pipeline references it:

1. Merge `scripts/assert-no-ea-build-args.sh` into toolbox — wait for Konflux to rebuild the toolbox image
2. Merge Renovate rule changes into rhaiis/containers and containers/bootc (immediately prevents new EA bumps on GA branches)
3. Merge aipcc-product-management-configs changes and regenerate PipelineRuns (adds `ea-build: "true"` to EA branch PipelineRuns — no effect yet since the pipeline doesn't read it)
4. Merge konflux-data task + pipeline changes last (activates the build-time check — by this point EA branches already have `ea-build: "true"` so they skip the check cleanly)
