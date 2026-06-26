# AIPCC-15422: test assert-all-images-are-stable with real Konflux builds

## Background

I added a new Tekton task `assert-all-images-are-stable` to our shared
build pipeline in the `konflux-data` repo (MR !418, branch
`AIPCC-15422-check-ea-images`). The task greps `.conf` build-arg files for
pre-release image tags (`-ea.` or `-fast.`) and fails the build if any are
found on a stable branch.

The pipeline has a `stable-release` parameter (default `"true"`). EA/fast
branches set it to `"false"` to skip the check. The task gates
`prefetch-dependencies`, so a failure stops the pipeline before the
expensive container build.

The task uses Trusted Artifacts to access source code (not PVC workspaces),
matching how the pipelines already work.

Unit tests pass locally (ShellSpec). Now I need to test with real Konflux
PipelineRuns before merging.

## How the pipeline reference works

PipelineRun YAMLs in `.tekton/` directories reference the shared pipeline
via a git resolver:

```yaml
pipelineRef:
  params:
  - name: revision
    value: main               # <-- change this to test the MR branch
  - name: pathInRepo
    value: pipelines/full-container.yaml
  resolver: git
```

To test the unmerged task, change `revision` from `main` to
`AIPCC-15422-check-ea-images`.

## Test target

Use `rhaiis-cpu-ubi9` in `rhaiis/containers` — it's the cheapest component.
The repo is cloned at:
repos/gitlab.com/redhat/rhel-ai/rhaiis/containers/

The PipelineRun file is:
`.tekton/rhaiis-cpu-ubi9-on-pull-request.yaml`

It currently has `skip-checks: "true"` and targets `main` only (CEL
expression: `target_branch == "main"`).

The current `build-args/cpu-ubi9.conf` on `main` has stable refs only:
```
BASE_IMAGE=quay.io/aipcc/base-images/cpu:3.4.0-1775569200
RHAIIS_VERSION=3.4.0
WHEEL_RELEASE_PROJECT_ID=68845358
WHEEL_RELEASE_PACKAGE=rhaiis-wheels
WHEEL_RELEASE_X86_64=3.4.2018+rhaiis-cpu-ubi9-x86_64
```

## What I need you to do

Create test MR branches in `rhaiis/containers` to run four Konflux test
scenarios. For each, modify `.tekton/rhaiis-cpu-ubi9-on-pull-request.yaml`
to point `pipelineRef.revision` to `AIPCC-15422-check-ea-images`.

### Test 1: GA build with stable images (should PASS)

- Branch from `main`
- Change only the `pipelineRef.revision` to `AIPCC-15422-check-ea-images`
- Do NOT add `stable-release` param (let it default to `"true"`)
- `skip-checks` stays `"true"` (that's fine, the assert task has its own
  `when` guard on `stable-release`, independent of `skip-checks`)
- Touch the `.tekton/` file or `build-args/cpu-ubi9.conf` to trigger the
  CEL expression

Expected: `assert-all-images-are-stable` runs and passes. Output:
"All image references in build-args/cpu-ubi9.conf are stable."

### Test 2: GA build with EA image refs (should FAIL)

- Branch from `main`
- Same `.tekton/` changes as Test 1
- Edit `build-args/cpu-ubi9.conf` to inject an EA ref:
  ```
  BASE_IMAGE=quay.io/aipcc/base-images/cpu:3.5.0-ea.1-1779804522
  ```

Expected: `assert-all-images-are-stable` runs and fails. Output:
"ERROR: Non-stable version references found in build-args/cpu-ubi9.conf"

### Test 3: GA build with fast image refs (should FAIL)

- Branch from `main`
- Same `.tekton/` changes as Test 1
- Edit `build-args/cpu-ubi9.conf` to inject a fast ref:
  ```
  BASE_IMAGE=quay.io/aipcc/base-images/cpu:3.5.0-fast.1-1779804522
  ```

Expected: same failure as Test 2.

### Test 4: EA branch with stable-release=false (should SKIP)

- Branch from `main`
- Same `.tekton/` changes as Test 1
- Add `stable-release: "false"` to the PipelineRun `params`
- Edit `build-args/cpu-ubi9.conf` to inject an EA ref (same as Test 2):
  ```
  BASE_IMAGE=quay.io/aipcc/base-images/cpu:3.5.0-ea.1-1779804522
  ```

Expected: `assert-all-images-are-stable` is skipped entirely (the `when`
clause gates on `stable-release == "true"`). The pipeline continues past
`prefetch-dependencies` without checking the conf file.

## How to create the test MRs

For each test, create a branch, make the changes, push, and open a Draft
MR targeting `main`. PipelinesAsCode will trigger the PipelineRun
automatically when the CEL expression matches.

```bash
cd repos/gitlab.com/redhat/rhel-ai/rhaiis/containers
git fetch origin main
git checkout -b test-stable-check-N origin/main
# ... make changes ...
git add -A && git commit -m "test assert-all-images-are-stable with <scenario>

Point pipelineRef to the unmerged AIPCC-15422 branch in
konflux-data to validate that the new assert task <expected behavior>."
git push -u origin test-stable-check-N
glab mr create --draft \
  --title "DO NOT MERGE: test assert-all-images-are-stable (<scenario>)" \
  --description "## Purpose

Test the unmerged assert-all-images-are-stable Tekton task from
[konflux-data MR !418](https://gitlab.com/redhat/rhel-ai/konflux-data/-/merge_requests/418)
(AIPCC-15422) against a real Konflux PipelineRun.

## What this tests

<describe the scenario and expected outcome>

## Cleanup

Close this MR and delete the branch after verifying results." \
  --target-branch main
```

## How to verify results

PipelinesAsCode posts pipeline status back to GitLab as commit statuses.
Query them to find the Konflux PipelineRun URL:

```bash
SHA=$(git rev-parse test-stable-check-N)
glab api projects/redhat%2Frhel-ai%2Frhaiis%2Fcontainers/repository/commits/${SHA}/statuses \
  | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if 'Konflux' in s['name']:
        print(s['status'], s['name'], s.get('target_url', ''))
"
```

This gives the PipelineRun name and Konflux UI link directly. The status
will be `running`, `success`, or `failed`.

### Getting task logs

Konflux aggressively garbage-collects PipelineRuns and Pods, so
`oc get pipelineruns` and `oc logs` will usually return nothing.
Use kubearchive (`oc ka`) instead — it archives PipelineRuns, TaskRuns,
Pods, and pod logs.

```bash
oc login --web https://api.stone-prod-p02.hjvn.p1.openshiftapps.com:6443

# 1. Find the assert TaskRun name from the PipelineRun:
oc ka get pipelinerun <PIPELINERUN_NAME> -n ai-tenant -o yaml \
  | grep -B2 'pipelineTaskName: assert-all-images-are-stable'

# 2. Find the pod for that TaskRun:
oc ka get pods -n ai-tenant \
  -l tekton.dev/taskRun=<TASKRUN_NAME>

# 3. Get the check step's log output:
oc ka logs <POD_NAME> -n ai-tenant -c step-check
```

The Konflux UI also shows logs (it queries kubearchive behind the scenes):
https://konflux-ui.apps.stone-prod-p02.hjvn.p1.openshiftapps.com/application-pipeline/workspaces/ai-tenant/applications/rhaiis

## Wait, then check the CEL expression

The CEL expression on the on-pull-request file is:
```
event == "pull_request" && target_branch == "main" && (
    ".tekton/rhaiis-cpu-ubi9-on-pull-request.yaml".pathChanged() ||
    "build-args/cpu-ubi9.conf".pathChanged() ||
    "Containerfile.cpu-ubi9".pathChanged() ||
    "ci".pathChanged()
)
```

Since we're modifying `.tekton/rhaiis-cpu-ubi9-on-pull-request.yaml` and/or
`build-args/cpu-ubi9.conf`, the CEL expression should match. All MRs
target `main`.

## Cleanup

After verifying results, close all test MRs and delete the branches:
```bash
glab mr close <MR_NUMBER> --repo redhat/rhel-ai/rhaiis/containers
git push origin --delete test-stable-check-N
```

Test images auto-expire after 5 days (`image-expires-after: 5d`).

## Deliverable

Report:
1. For each test: the MR URL, PipelineRun name, assert task status
   (passed/failed/skipped), and the task's log output
2. Whether the pipeline gating works (did `prefetch-dependencies` wait for
   the assert task?)
3. Any unexpected behavior or failures
