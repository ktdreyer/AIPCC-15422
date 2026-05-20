# AIPCC-15422: Non-EA branches must not use EA image versions

## Context

EA (Early Access) image versions can accidentally end up in GA (Generally Available) builds if someone manually edits a build-args conf file or if Renovate proposes an EA image bump on a GA branch. There is no guardrail today. This plan adds two complementary layers: a Renovate rule to prevent EA bumps from being proposed, and a Tekton pipeline check to catch EA images at build time regardless of how they got there.

## Approach

### Layer 1: Tekton pipeline check (4 repos)

**konflux-data** — `pipelines/full-container.yaml` and `pipelines/disk-image-container.yaml`:
- Add `ea-build` string parameter (default `"false"`)
- Add `check-ea-images` task, gated by `when: ea-build in ["false"]` and `skip-checks in ["false"]`
- Task clones source (workspace already available), runs the repo's `has-ea-images` script, fails if it exits 0 (EA images found)

**konflux-data** — new `tasks/check-ea-images.yaml`:
- Receives the source workspace and `build-args-file` parameter
- Runs `has-ea-images` from the repo root
- Description: "Runs the repo's has-ea-images script and fails the build if EA image references are found in the build configuration."
- Uses a lightweight image (e.g. `registry.access.redhat.com/ubi9-minimal`)
- Fails with a clear error message listing which images matched

**rhaiis/containers** — new `has-ea-images` script:
- Parses `build-args/*.conf` files
- Greps image values (`BASE_IMAGE=`) for `-ea.` in the tag
- Exits 0 if EA images found, 1 if clean

**containers/bootc** — new `has-ea-images` script:
- Parses `argfile-*.conf` files
- Greps image values (`BASE_IMAGE=`, `VLLM_IMAGE=`, `MODEL_OPT_IMAGE=`) for `-ea.` in the tag
- Exits 0 if EA images found, 1 if clean

**aipcc-product-management-configs** — EA branch config files:
- Add `extra_params: [{name: ea-build, value: "true"}]` to EA branch product configs
- The existing `extra_params` mechanism in the PipelineRun Jinja template already supports this — no template changes needed
- Regenerate PipelineRun files with `onboard-product.py`

### Layer 2: Renovate rules (2 repos)

**rhaiis/containers** — `renovate.json`:
- Add packageRule blocking EA versions on GA branches:
  ```json
  {
    "description": "Block EA image versions on non-EA branches",
    "matchPackageNames": ["/^quay\\.io\\/aipcc\\//"],
    "matchBaseBranches": ["main", "3.0", "3.1", "3.2"],
    "allowedVersions": "/^(?!.*-ea\\.).*$/"
  }
  ```

**containers/bootc** — `renovate.json`:
- Add equivalent packageRule:
  ```json
  {
    "description": "Block EA image versions on non-EA branches",
    "matchPackageNames": ["quay.io/aipcc/rhaiis/**", "quay.io/aipcc/rhaiis-model-opt/**"],
    "matchBaseBranches": ["/^main$|^\\d+\\.\\d+$/"],
    "allowedVersions": "/^(?!.*-ea\\.).*$/"
  }
  ```
- Uses regex for `matchBaseBranches` to match the existing `baseBranchPatterns` style in this repo

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

1. Merge `has-ea-images` scripts into rhaiis/containers and containers/bootc first (no effect until pipeline calls them)
2. Merge Renovate rule changes (immediately prevents new EA bumps on GA branches)
3. Merge konflux-data pipeline + task changes (activates the build-time check)
4. Merge aipcc-product-management-configs changes and regenerate PipelineRuns (enables EA branches to skip the check)
