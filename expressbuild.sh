#!/bin/bash
set -euo pipefail

# ExpressVPN Docker build helper.
# Version + installer checksum come from expressvpn.env (single source of truth).
# The universal .run is multi-arch, so one image supports amd64 and arm64.

usage() {
  cat >&2 <<EOF
Usage: $0 <repository> [tag] [options]

Arguments:
  repository            Image repository, e.g. ghcr.io/you/expressvpn or you/expressvpn
  tag                   Image tag (default: ExpressVPN build version)

Options:
  --platform <list>     Comma-separated platforms (default: host arch)
                        e.g. --platform linux/amd64,linux/arm64
  --push                Push to the registry (required for multi-arch)
  --load                Load into the local docker (default; single-arch only)
  -h, --help            Show this help

Examples:
  $0 you/expressvpn                                    # local, version-tagged host arch
  $0 ghcr.io/you/expressvpn v1 --platform linux/amd64,linux/arm64 --push
EOF
  exit 1
}

main() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Check arguments before touching the env file, so a bare invocation prints
  # usage instead of failing with a sourcing error.
  [[ $# -lt 1 ]] && usage

  if [[ ! -r "${script_dir}/expressvpn.env" ]]; then
    echo "Cannot read ${script_dir}/expressvpn.env" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source "${script_dir}/expressvpn.env"
  : "${EXPRESSVPN_VERSION:?EXPRESSVPN_VERSION missing from expressvpn.env}"
  : "${EXPRESSVPN_SHA256:?EXPRESSVPN_SHA256 missing from expressvpn.env}"

  local repository="" tag="${EXPRESSVPN_VERSION}" platform="" output="--load"
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform)
        [[ $# -ge 2 ]] || { echo "--platform requires a value" >&2; usage; }
        platform="$2"; shift 2 ;;
      --push) output="--push"; shift ;;
      --load) output="--load"; shift ;;
      -h|--help) usage ;;
      -*) echo "Unknown option: $1" >&2; usage ;;
      *) positional+=("$1"); shift ;;
    esac
  done

  [[ ${#positional[@]} -ge 1 ]] || usage
  repository="${positional[0]}"
  [[ ${#positional[@]} -ge 2 ]] && tag="${positional[1]}"

  local image_name="${repository}:${tag}"

  local build_args=(
    --build-arg "EXPRESSVPN_VERSION=${EXPRESSVPN_VERSION}"
    --build-arg "EXPRESSVPN_SHA256=${EXPRESSVPN_SHA256}"
    -t "$image_name"
  )
  [[ -n "$platform" ]] && build_args+=(--platform "$platform")
  build_args+=("$output")

  if [[ "$output" != "--push" && "$platform" == *,* ]]; then
    echo "Multi-arch builds cannot be --load; use --push." >&2
    exit 1
  fi

  echo "Building ${image_name} (ExpressVPN ${EXPRESSVPN_VERSION}, ${platform:-host arch}, ${output#--})"
  docker buildx build "${build_args[@]}" "${script_dir}"
}

main "$@"
