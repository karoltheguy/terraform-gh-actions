#!/usr/bin/env bash
#
# Copyright 2021 The terraform-docs Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o pipefail
set -o errtrace

# Forgejo/act-runner compatibility: Remove unevaluated template expressions
# When Forgejo doesn't properly interpolate ${{ inputs.* }} expressions,
# they appear as literal strings. We strip them out to use defaults instead.
strip_template_expressions() {
    local value="$1"
    # If value contains ${{ or }}, it's an unevaluated expression
    if [[ "$value" == *'${{'* ]] || [[ "$value" == *'}}'* ]]; then
        echo ""
    else
        echo "$value"
    fi
}

# Clean all INPUT variables that might contain template expressions
INPUT_OUTPUT_FORMAT=$(strip_template_expressions "${INPUT_OUTPUT_FORMAT}")
INPUT_ARGS=$(strip_template_expressions "${INPUT_ARGS}")
INPUT_TEMPLATE=$(strip_template_expressions "${INPUT_TEMPLATE}")
INPUT_INDENTION=$(strip_template_expressions "${INPUT_INDENTION}")
INPUT_OUTPUT_METHOD=$(strip_template_expressions "${INPUT_OUTPUT_METHOD}")
INPUT_OUTPUT_FILE=$(strip_template_expressions "${INPUT_OUTPUT_FILE}")
INPUT_CONFIG_FILE=$(strip_template_expressions "${INPUT_CONFIG_FILE}")
INPUT_RECURSIVE=$(strip_template_expressions "${INPUT_RECURSIVE}")
INPUT_RECURSIVE_PATH=$(strip_template_expressions "${INPUT_RECURSIVE_PATH}")
INPUT_WORKING_DIR=$(strip_template_expressions "${INPUT_WORKING_DIR}")
INPUT_ATLANTIS_FILE=$(strip_template_expressions "${INPUT_ATLANTIS_FILE}")
INPUT_FIND_DIR=$(strip_template_expressions "${INPUT_FIND_DIR}")
INPUT_GIT_PUSH=$(strip_template_expressions "${INPUT_GIT_PUSH}")
INPUT_GIT_PUSH_USER_NAME=$(strip_template_expressions "${INPUT_GIT_PUSH_USER_NAME}")
INPUT_GIT_PUSH_USER_EMAIL=$(strip_template_expressions "${INPUT_GIT_PUSH_USER_EMAIL}")
INPUT_GIT_COMMIT_MESSAGE=$(strip_template_expressions "${INPUT_GIT_COMMIT_MESSAGE}")
INPUT_GIT_PUSH_SIGN_OFF=$(strip_template_expressions "${INPUT_GIT_PUSH_SIGN_OFF}")
INPUT_GIT_SUB_DIR=$(strip_template_expressions "${INPUT_GIT_SUB_DIR}")
INPUT_FAIL_ON_DIFF=$(strip_template_expressions "${INPUT_FAIL_ON_DIFF}")

# Use defaults if values were stripped or empty (must match action.yml defaults)
INPUT_OUTPUT_FORMAT="${INPUT_OUTPUT_FORMAT:-markdown table}"
INPUT_INDENTION="${INPUT_INDENTION:-2}"
INPUT_OUTPUT_METHOD="${INPUT_OUTPUT_METHOD:-inject}"
INPUT_OUTPUT_FILE="${INPUT_OUTPUT_FILE:-README.md}"
INPUT_CONFIG_FILE="${INPUT_CONFIG_FILE:-disabled}"
INPUT_RECURSIVE="${INPUT_RECURSIVE:-false}"
INPUT_RECURSIVE_PATH="${INPUT_RECURSIVE_PATH:-modules}"
INPUT_WORKING_DIR="${INPUT_WORKING_DIR:-.}"
INPUT_ATLANTIS_FILE="${INPUT_ATLANTIS_FILE:-disabled}"
INPUT_FIND_DIR="${INPUT_FIND_DIR:-disabled}"
INPUT_GIT_PUSH="${INPUT_GIT_PUSH:-false}"
INPUT_GIT_COMMIT_MESSAGE="${INPUT_GIT_COMMIT_MESSAGE:-terraform-docs: automated action}"
INPUT_GIT_PUSH_SIGN_OFF="${INPUT_GIT_PUSH_SIGN_OFF:-false}"
INPUT_FAIL_ON_DIFF="${INPUT_FAIL_ON_DIFF:-false}"

# shellcheck disable=SC2206
cmd_args=(${INPUT_OUTPUT_FORMAT})

# shellcheck disable=SC2206
cmd_args+=(${INPUT_ARGS})

if [ "${INPUT_CONFIG_FILE}" = "disabled" ]; then
    case "$INPUT_OUTPUT_FORMAT" in
    "asciidoc" | "asciidoc table" | "asciidoc document")
        cmd_args+=(--indent "${INPUT_INDENTION}")
        ;;

    "markdown" | "markdown table" | "markdown document")
        cmd_args+=(--indent "${INPUT_INDENTION}")
        ;;
    esac

    if [ -z "${INPUT_TEMPLATE}" ]; then
        INPUT_TEMPLATE=$(printf '<!-- BEGIN_TF_DOCS -->\n{{ .Content }}\n<!-- END_TF_DOCS -->')
    fi
fi

if [ -z "${INPUT_GIT_PUSH_USER_NAME}" ]; then
    INPUT_GIT_PUSH_USER_NAME="actions[bot]"
fi

if [ -z "${INPUT_GIT_PUSH_USER_EMAIL}" ]; then
    INPUT_GIT_PUSH_USER_EMAIL="actions[bot]@users.noreply.localhost"
fi

# Support both GitHub and Forgejo environment variables
WORKSPACE="${FORGEJO_WORKSPACE:-${GITHUB_WORKSPACE}}"
OUTPUT_PATH="${FORGEJO_OUTPUT:-${GITHUB_OUTPUT}}"

if [ -n "${INPUT_GIT_SUB_DIR}" ]; then
    WORKSPACE="${WORKSPACE}/${INPUT_GIT_SUB_DIR}"
    echo "Using non-standard workspace of ${WORKSPACE}"
fi

git_setup() {
    # When the runner maps the workspace mount, it is owned by the runner
    # user while the created folders are owned by the container user, causing
    # permission issues. Works for both GitHub and Forgejo runners.
    # See: https://github.com/actions/checkout/issues/766
    git config --global --add safe.directory "${WORKSPACE}"

    git config --global user.name "${INPUT_GIT_PUSH_USER_NAME}"
    git config --global user.email "${INPUT_GIT_PUSH_USER_EMAIL}"
    git fetch --depth=1 origin +refs/tags/*:refs/tags/* || true
}

git_add() {
    local file
    file="$1"
    git add "${file}"
    if [ "$(git status --porcelain | grep "$file" | grep -c -E '([MA]\W).+')" -eq 1 ]; then
        echo "::debug Added ${file} to git staging area"
    else
        echo "::debug No change in ${file} detected"
    fi
}

git_status() {
    git status --porcelain | grep -c -E '([MA]\W).+' || true
}

git_commit() {
    if [ "$(git_status)" -eq 0 ]; then
        echo "::debug No files changed, skipping commit"
        exit 0
    fi

    echo "::debug Following files will be committed"
    git status -s

    local args=(
        -m "${INPUT_GIT_COMMIT_MESSAGE}"
    )

    if [ "${INPUT_GIT_PUSH_SIGN_OFF}" = "true" ]; then
        args+=("-s")
    fi

    git commit "${args[@]}"
}

update_doc() {
    local working_dir
    working_dir="$1"
    echo "::debug working_dir=${working_dir}"

    local exec_args
    exec_args=( "${cmd_args[@]}" )

    if [ -n "${INPUT_CONFIG_FILE}" ] && [ "${INPUT_CONFIG_FILE}" != "disabled" ]; then
        local config_file

        if [ -f "${INPUT_CONFIG_FILE}" ]; then
            config_file="${INPUT_CONFIG_FILE}"
        else
            config_file="${working_dir}/${INPUT_CONFIG_FILE}"
        fi

        echo "::debug config_file=${config_file}"
        exec_args+=(--config "${config_file}")
    fi

    if [ "${INPUT_OUTPUT_METHOD}" == "inject" ] || [ "${INPUT_OUTPUT_METHOD}" == "replace" ]; then
        echo "::debug output_mode=${INPUT_OUTPUT_METHOD}"
        exec_args+=(--output-mode "${INPUT_OUTPUT_METHOD}")

        echo "::debug output_file=${INPUT_OUTPUT_FILE}"
        exec_args+=(--output-file "${INPUT_OUTPUT_FILE}")
    fi

    if [ -n "${INPUT_TEMPLATE}" ]; then
        exec_args+=(--output-template "${INPUT_TEMPLATE}")
    fi

    if [ "${INPUT_RECURSIVE}" = "true" ]; then
        if [ -n "${INPUT_RECURSIVE_PATH}" ]; then
            exec_args+=(--recursive)
            exec_args+=(--recursive-path "${INPUT_RECURSIVE_PATH}")
        fi
    fi

    exec_args+=("${working_dir}")

    local success

    echo "::debug terraform-docs" "${exec_args[@]}"
    terraform-docs "${exec_args[@]}"
    success=$?

    if [ $success -ne 0 ]; then
        exit $success
    fi

    if [ "${INPUT_OUTPUT_METHOD}" == "inject" ] || [ "${INPUT_OUTPUT_METHOD}" == "replace" ]; then
        git_add "${working_dir}/${OUTPUT_FILE}"
    fi
}

# go to repository workspace
cd "${WORKSPACE}"

git_setup

if [ -f "${WORKSPACE}/${INPUT_ATLANTIS_FILE}" ]; then
    # Parse an atlantis yaml file
    for line in $(yq e '.projects[].dir' "${WORKSPACE}/${INPUT_ATLANTIS_FILE}"); do
        update_doc "${line//- /}"
    done
elif [ -n "${INPUT_FIND_DIR}" ] && [ "${INPUT_FIND_DIR}" != "disabled" ]; then
    # Find all tf
    for project_dir in $(find "${INPUT_FIND_DIR}" -name '*.tf' -exec dirname {} \; | uniq); do
        update_doc "${project_dir}"
    done
else
    # Split INPUT_WORKING_DIR by commas
    for project_dir in ${INPUT_WORKING_DIR//,/ }; do
        update_doc "${project_dir}"
    done
fi

# always set num_changed output
set +e
num_changed=$(git_status)
set -e
echo "num_changed=${num_changed}" >> "$OUTPUT_PATH"

if [ "${INPUT_GIT_PUSH}" = "true" ]; then
    git_commit
    git push
else
    if [ "${INPUT_FAIL_ON_DIFF}" = "true" ] && [ "${num_changed}" -ne 0 ]; then
        echo "::error ::Uncommitted change(s) has been found!"
        exit 1
    fi
fi

exit 0
