#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

function timestamp() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%S).000Z"
}

function log() {
  echo "$(timestamp) [${1}] ${*:2}" >&2
  if [[ "${1}" == "FATAL" ]]; then
    exit 1
  fi
}

[ -z "${HEAD_SHA:-}" ] && log FATAL "HEAD_SHA environment variable is required"
[ -z "${BASE_SHA:-}" ] && log FATAL "BASE_SHA environment variable is required"

readarray -t changed_files < <(git diff --no-renames --name-only --merge-base "${BASE_SHA}" "${HEAD_SHA}" --)
readarray -t applications < <(git ls-files 'apps/*.yaml')

# map the Application manifest, its paths in this repo and its value files to the app name
declare -A owners=()
for app in "${applications[@]}"; do
  name="${app#apps/}"
  name="${name%.yaml}"
  owners["${app}"]+=" ${name}"

  while IFS= read -r path; do
    owners["${path}"]+=" ${name}"
  done < <(yq -o=json -I=0 '.' "${app}" | jq -r '
    (.spec.sources // [.spec.source])[] |
      (.path // empty),
      (.helm.valueFiles[]? | sub("^\\$values/"; ""))
  ')
done

changed_apps=()
for file in "${changed_files[@]}"; do
  if [[ "${file}" == policies/* ]]; then
    log INFO "replacing '${file}' with every app"
    for app in "${applications[@]}"; do
      name="${app#apps/}"
      changed_apps+=("${name%.yaml}")
    done
    continue
  fi

  matched=false
  for path in "${!owners[@]}"; do
    if [[ "${file}" == "${path}" || "${file}" == "${path}/"* ]]; then
      read -ra names <<<"${owners[${path}]}"
      changed_apps+=("${names[@]}")
      matched=true
    fi
  done

  if [[ "${matched}" == true ]]; then
    continue
  fi

  dir=$(dirname "${file}")
  while [[ "${dir}" != "." ]]; do
    if [[ -f "${dir}/kustomization.yaml" ]]; then
      log FATAL "'${file}' changed but no Application uses '${dir}'"
    fi
    dir=$(dirname "${dir}")
  done

  log INFO "ignoring changes in '${file}' - not used by an Application"
done

# Convert to JSON-encoded string
appJson="$(jq --null-input --compact-output '$ARGS.positional | unique' --args -- "${changed_apps[@]}")"

if [[ -n ${GITHUB_OUTPUT+x} ]]; then
  echo "matrix=$appJson" | tee -a "$GITHUB_OUTPUT"
else
  echo "matrix=$appJson"
fi
