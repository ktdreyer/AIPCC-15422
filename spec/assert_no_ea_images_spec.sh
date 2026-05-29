#!/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

eval "$(shellspec - -c) exit 1"

task_path=assert-no-ea-images-inline-task.yaml
if [[ -f "../${task_path}" ]]; then
    task_path="../${task_path}"
fi

cleanup=()
trap 'rm -rf "${cleanup[@]}"' EXIT

workspace_dir=$(mktemp -d) && cleanup+=("${workspace_dir}")

extract_script() {
    local script
    script="$(mktemp --tmpdir script_XXXXXXXXXX.sh)"
    # Wrap to simulate Tekton's workingDir
    echo "cd ${workspace_dir}" > "${script}"
    yq -r ".spec.steps[] | select(.name == \"$1\").script" "${task_path}" >> "${script}"
    # Replace Tekton variable references with test values
    sed -i 's|$(params.BUILD_ARGS_FILE)|'"${BUILD_ARGS_FILE}"'|g' "${script}"
    sed -i 's|$(workspaces.source.path)|'"${workspace_dir}"'|g' "${script}"
    chmod +x "${script}"
    echo "${script}"
}

write_conf() {
    local name="$1"
    shift
    local file="${workspace_dir}/${name}"
    printf '%s\n' "$@" > "${file}"
    echo "${file}"
}

setup_test() {
    rm -f "${workspace_dir}"/*.conf
}

Describe "assert-no-ea-images task"
    BeforeEach setup_test

    It "passes when build-args-file param is empty"
        export BUILD_ARGS_FILE=""
        check_script="$(extract_script check)"
        cleanup+=("${check_script}")
        When call "${check_script}"
        The output should include "No build-args-file specified"
        The status should be success
    End

    It "passes when conf file does not exist"
        export BUILD_ARGS_FILE="nonexistent.conf"
        check_script="$(extract_script check)"
        cleanup+=("${check_script}")
        When call "${check_script}"
        The output should include "Build-args file not found"
        The status should be success
    End

    It "passes on an empty conf file"
        write_conf "empty.conf"
        export BUILD_ARGS_FILE="empty.conf"
        check_script="$(extract_script check)"
        cleanup+=("${check_script}")
        When call "${check_script}"
        The output should include "No EA version references"
        The status should be success
    End

    It "passes on GA rhaiis build-args"
        write_conf "ga-rhaiis.conf" \
            "# GA build-args" \
            "BASE_IMAGE=quay.io/aipcc/base-images/cuda-13.0-el9.6:3.4.0-1775836636" \
            "RHAIIS_VERSION=3.4.0"
        export BUILD_ARGS_FILE="ga-rhaiis.conf"
        check_script="$(extract_script check)"
        cleanup+=("${check_script}")
        When call "${check_script}"
        The output should include "No EA version references"
        The status should be success
    End

    It "passes on GA bootc argfile"
        write_conf "ga-bootc.conf" \
            "BASE_IMAGE=registry.redhat.io/rhel9-eus/rhel-9.6-bootc:9.6-1778650389" \
            "RHELAI_VERSION_ID=3.4.0" \
            "VLLM_IMAGE=quay.io/aipcc/rhaiis/cuda-ubi9:3.4.0-1777444689" \
            "MODEL_OPT_IMAGE=quay.io/aipcc/rhaiis-model-opt/cuda-ubi9:3.4.0-1777899109"
        export BUILD_ARGS_FILE="ga-bootc.conf"
        check_script="$(extract_script check)"
        cleanup+=("${check_script}")
        When call "${check_script}"
        The output should include "No EA version references"
        The status should be success
    End

    It "fails on lowercase -ea. in image tag"
        write_conf "ea-lowercase.conf" \
            "BASE_IMAGE=quay.io/aipcc/base-images/cuda-13.0-el9.6:3.4.0-ea.1-1775836636"
        export BUILD_ARGS_FILE="ea-lowercase.conf"
        check_script="$(extract_script check)"
        cleanup+=("${check_script}")
        When call "${check_script}"
        The output should include "ERROR: EA version references"
        The status should be failure
    End

    It "fails on uppercase -EA. in image tag"
        write_conf "ea-uppercase.conf" \
            "VLLM_IMAGE=quay.io/aipcc/rhaiis/cuda-ubi9:3.4.0-EA.1-1777444689"
        export BUILD_ARGS_FILE="ea-uppercase.conf"
        check_script="$(extract_script check)"
        cleanup+=("${check_script}")
        When call "${check_script}"
        The output should include "ERROR: EA version references"
        The status should be failure
    End

    It "fails on EA bootc argfile (mixed GA and EA values)"
        write_conf "ea-bootc.conf" \
            "BASE_IMAGE=registry.redhat.io/rhel9-eus/rhel-9.6-bootc:9.6-1778650389" \
            "RHELAI_VERSION_ID=3.5-EA1" \
            "VLLM_IMAGE=quay.io/aipcc/rhaiis/cuda-ubi9:3.5.0-ea.1-1777444689" \
            "MODEL_OPT_IMAGE=quay.io/aipcc/rhaiis-model-opt/cuda-ubi9:3.5.0-ea.1-1777899109"
        export BUILD_ARGS_FILE="ea-bootc.conf"
        check_script="$(extract_script check)"
        cleanup+=("${check_script}")
        When call "${check_script}"
        The output should include "ERROR: EA version references"
        The status should be failure
    End

    It "passes on version ID with -EA1 (no dot after EA)"
        write_conf "version-id.conf" \
            "RHELAI_VERSION_ID=3.5-EA1" \
            "RHELAI_REPO_VERSION=3.5" \
            "BASE_IMAGE=registry.redhat.io/rhel9-eus/rhel-9.6-bootc:9.6-1778650389"
        export BUILD_ARGS_FILE="version-id.conf"
        check_script="$(extract_script check)"
        cleanup+=("${check_script}")
        When call "${check_script}"
        The output should include "No EA version references"
        The status should be success
    End
End
