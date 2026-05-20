# [AIPCC-15422](https://redhat.atlassian.net/browse/AIPCC-15422): Non-EA branches must not use EA image versions

## Context

EA (Early Access) image versions can accidentally end up in GA (Generally Available) builds if someone manually edits a build-args conf file or if Renovate proposes an EA image bump on a GA branch. There is no guardrail today. This plan adds two complementary layers: a Renovate rule to prevent EA bumps from being proposed, and a Tekton pipeline check to catch EA images at build time regardless of how they got there.

## Approach

### Why two layers?

Renovate rules are preventive — they stop bad merge requests from being opened. But they only cover automated dependency bumps. A developer could manually edit a conf file and introduce an EA image reference. The pipeline check catches everything at build time regardless of how the EA reference got there. Neither layer alone is sufficient.

### Layer 1: Tekton pipeline check (4 repos)

**[konflux-data](https://gitlab.com/redhat/rhel-ai/konflux-data)** — `pipelines/full-container.yaml` and `pipelines/disk-image-container.yaml`:
- Add `ea-build` string parameter (default `"false"`). We use `ea-build` rather than `skip-ea-check` or `allow-ea-images` because it describes a fact about the build ("this is an EA build") rather than a permission or action. This makes it harder to misuse as a workaround — setting `ea-build: "true"` on a GA branch would be a factual lie, not just flipping a switch.
- Add `check-ea-images` task, gated by `when: ea-build in ["false"]` and `skip-checks in ["false"]` (same pattern as the existing [`deprecated-base-image-check`](https://gitlab.com/redhat/rhel-ai/konflux-data/-/blob/a029a2edeb91523e985b1c0fd1a4ece5b597c75f/pipelines/full-container.yaml#L375-396) task)
- Task clones source (workspace already available), runs the repo's `has-ea-images` script, fails if it exits 0 (EA images found)

**[konflux-data](https://gitlab.com/redhat/rhel-ai/konflux-data)** — new [`tasks/check-ea-images.yaml`](https://gitlab.com/redhat/rhel-ai/konflux-data/-/tree/a029a2edeb91523e985b1c0fd1a4ece5b597c75f/tasks):
- Receives the source workspace and `build-args-file` parameter
- Runs `has-ea-images` from the repo root
- Description: "Runs the repo's has-ea-images script and fails the build if EA image references are found in the build configuration."
- Uses a lightweight image (e.g. `registry.access.redhat.com/ubi9-minimal`)
- Fails with a clear error message listing which images matched

**[rhaiis/containers](https://gitlab.com/redhat/rhel-ai/rhaiis/containers)** — new `has-ea-images` script:
- Parses [`build-args/*.conf`](https://gitlab.com/redhat/rhel-ai/rhaiis/containers/-/blob/f9e768a501322e57a3d6880b7784c2d6e22a18b4/build-args/cuda-ubi9.conf) files
- Greps image values (`BASE_IMAGE=`) for `-ea.` in the tag
- Exits 0 if EA images found, 1 if clean

**[containers/bootc](https://gitlab.com/redhat/rhel-ai/containers/bootc)** — new `has-ea-images` script:
- Parses [`argfile-*.conf`](https://gitlab.com/redhat/rhel-ai/containers/bootc/-/blob/26934ab380776e843bdf6c95a5a52c9e952bd5d5/argfile-cuda.conf) files
- Greps image values (`BASE_IMAGE=`, `VLLM_IMAGE=`, `MODEL_OPT_IMAGE=`) for `-ea.` in the tag
- Exits 0 if EA images found, 1 if clean

**Why per-repo scripts instead of a generic task?** Each container repo has its own conf file format and image key names. For example, rhaiis/containers uses `build-args/cuda-ubi9.conf` with a single `BASE_IMAGE` key, while containers/bootc uses `argfile-cuda.conf` with `BASE_IMAGE`, `VLLM_IMAGE`, and `MODEL_OPT_IMAGE`. If we put this parsing logic in the shared Tekton task in konflux-data, it would need to hard-code these details — and when rhaiis adds a new image key or bootc renames a conf file, the shared task would silently miss the new references. With per-repo scripts, each repo owns its detection logic and can update it alongside the conf file changes in the same merge request.

**[aipcc-product-management-configs](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management-configs)** — EA branch config files:
- Add `extra_params: [{name: ea-build, value: "true"}]` to EA branch product configs
- The existing [`extra_params` mechanism](https://gitlab.com/redhat/rhel-ai/ci-cd/aipcc-product-management/-/blob/b63baddf9d061140fa9a9afe3da26cfaa351b53e/templates/pipelinerun/full-container.yaml.j2#L99-102) in the PipelineRun Jinja template already supports this — no template changes needed
- Regenerate PipelineRun files with `onboard-product.py`

**Why `extra_params` instead of a new template variable?** The Jinja template already iterates over `extra_params` and emits arbitrary pipeline parameters. Adding `ea-build` this way requires zero template code changes — just a config data change in the product YAML files. This also avoids the need to modify `onboard-product.py` itself.

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
| konflux-data | `pipelines/full-container.yaml` | Add `ea-build` param, wire `check-ea-images` task |
| konflux-data | `pipelines/disk-image-container.yaml` | Same |
| konflux-data | `tasks/check-ea-images.yaml` | New task definition |
| rhaiis/containers | `has-ea-images` | New script |
| rhaiis/containers | `renovate.json` | Add EA blocking packageRule |
| containers/bootc | `has-ea-images` | New script |
| containers/bootc | `renovate.json` | Add EA blocking packageRule |
| aipcc-product-management-configs | EA branch config files | Add `extra_params` for `ea-build` |

## Verification

1. **has-ea-images scripts**: Test locally by running against current conf files (should exit 1 on GA branches since they use GA images)
2. **Tekton task**: Validate YAML with `tkn task validate` or `oc apply --dry-run=client`
3. **Pipeline changes**: Validate with `tkn pipeline validate` or dry-run
4. **Renovate rules**: Test regex patterns against known EA version strings (e.g. `3.4.0-ea.1-1777444689` should be blocked, `3.4.0-1777444689` should pass)
5. **PipelineRun generation**: Run `onboard-product.py` with EA configs and verify `ea-build: "true"` appears in generated `.tekton/*.yaml` files; run existing tests with `uv run python -m pytest`

## Rollout order

This order avoids breaking EA builds while progressively adding protection to GA builds:

1. Merge `has-ea-images` scripts into rhaiis/containers and containers/bootc first (no effect until pipeline calls them)
2. Merge Renovate rule changes (immediately prevents new EA bumps on GA branches)
3. Merge aipcc-product-management-configs changes and regenerate PipelineRuns (adds `ea-build: "true"` to EA branch PipelineRuns — no effect yet since the pipeline doesn't read it)
4. Merge konflux-data pipeline + task changes last (activates the build-time check — by this point EA branches already have `ea-build: "true"` so they skip the check cleanly)
