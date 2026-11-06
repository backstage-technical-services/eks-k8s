#!/usr/bin/env bash
set -euo pipefail

app=$1
out=$2

render_path() {
  local path=$1 include=$2

  if [[ -f "${path}/kustomization.yaml" ]]; then
    kubectl kustomize "${path}"
    echo '---'
    return
  fi

  local files=()
  if [[ -n "${include}" ]]; then
    include=${include#\{}
    include=${include%\}}
    IFS=, read -ra files <<<"${include}"
    files=("${files[@]/#/${path}/}")
  else
    files=("${path}"/*.yaml)
  fi

  for file in "${files[@]}"; do
    echo '---'
    cat "${file}"
  done
}

render_chart() {
  local release=$1 namespace=$2 source=$3
  local values=()

  while IFS= read -r file; do
    values+=(-f "${file}")
  done < <(jq -r '.helm.valueFiles[]? | sub("^\\$values/"; "")' <<<"${source}")

  helm template "$(jq -r --arg name "${release}" '.helm.releaseName // $name' <<<"${source}")" \
    "$(jq -r '.chart' <<<"${source}")" \
    --repo "$(jq -r '.repoURL' <<<"${source}")" \
    --version "$(jq -r '.targetRevision' <<<"${source}")" \
    --namespace "${namespace}" \
    --include-crds \
    "${values[@]}"
}

application=$(yq -o=json -I=0 '.' "${app}")
name=$(jq -r '.metadata.name' <<<"${application}")
namespace=$(jq -r '.spec.destination.namespace' <<<"${application}")

mkdir -p "${out}"
rm -f "${out}/manifests.yaml" "${out}/helm.yaml"

while IFS= read -r source; do
  if jq -e '.chart' <<<"${source}" >/dev/null; then
    echo "Rendering chart $(jq -r '"\(.chart) \(.targetRevision)"' <<<"${source}")"
    render_chart "${name}" "${namespace}" "${source}" >>"${out}/helm.yaml"
  elif jq -e '.path' <<<"${source}" >/dev/null; then
    echo "Rendering $(jq -r '.path' <<<"${source}")"
    render_path "$(jq -r '.path' <<<"${source}")" "$(jq -r '.directory.include // ""' <<<"${source}")" >>"${out}/manifests.yaml"
  elif ! jq -e '.ref' <<<"${source}" >/dev/null; then
    echo "${app}: unsupported source $(jq -c '.' <<<"${source}")" >&2
    exit 1
  fi
done < <(jq -c '(.spec.sources // [.spec.source])[]' <<<"${application}")
