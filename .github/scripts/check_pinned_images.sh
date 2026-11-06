#!/bin/bash
# Fail if a container image CI or the release build pulls isn't pinned to a digest.
#
# A tag can be moved under us; a digest cannot. Checks `container:` and `image:`
# in .github/workflows/*.yml, and the base images the Dockerfile takes from its
# ARG defaults. Images we build ourselves have no upstream to pin and are exempt.
#
#   .github/scripts/check_pinned_images.sh
#
# Runs in CI from the "Pinned images" job in .github/workflows/ci.yml. Dependabot
# bumps the Dockerfile's pins (docker ecosystem in .github/dependabot.yml) but
# cannot see a workflow's `container:`, so those move by hand, with the Dockerfile.

set -uo pipefail

cd "$(dirname "$(realpath "$0")")/../.." || exit 1

# The image CI builds for its smoke test.
SELF_BUILT='^hcp-conformance(:|$)'

problems=0

report() {
  problems=$((problems + 1))
  echo "  ${1}"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error file=${2},line=${3}::${1}"
  fi
}

echo "==> Checking workflow image references are pinned to a digest"

# Anchored to the start of the line, so an `image:` inside a shell command is
# not read as a reference. A value taken from the matrix (`${{ matrix.image }}`)
# is fine: the matrix's own `image:` entries are on this list too.
while IFS=: read -r file line ref; do
  [ -z "${ref}" ] && continue
  raw="${ref%%#*}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  ref="${raw//\"/}"
  ref="${ref//\'/}"
  case "${ref}" in
    '${{'*) continue ;;
  esac
  if echo "${ref}" | grep -qE "${SELF_BUILT}"; then
    continue
  fi
  if ! echo "${ref}" | grep -q '@sha256:'; then
    report "${raw} is not pinned to a digest" "${file}" "${line}"
  fi
done < <(grep -rnE '^[[:space:]]*(-[[:space:]]*)?(container|image):[[:space:]]*[^[:space:]]+' \
  .github/workflows/*.yml 2>/dev/null |
  sed -E 's/^([^:]+):([0-9]+):[[:space:]]*(-[[:space:]]*)?(container|image):[[:space:]]*/\1:\2:/')

echo "==> Checking Dockerfile base images are pinned to a digest"

# The Dockerfile takes its bases from build args, so the defaults are what pin.
while IFS=: read -r line arg; do
  [ -z "${arg}" ] && continue
  if ! echo "${arg}" | grep -q '@sha256:'; then
    report "${arg} in Dockerfile is not pinned to a digest" "Dockerfile" "${line}"
  fi
done < <(grep -nE '^ARG [A-Z_]*IMAGE=' Dockerfile | sed -E 's/^([0-9]+):ARG /\1:/')

if [ "${problems}" -eq 0 ]; then
  echo "All image references are pinned."
  exit 0
fi

echo
echo "${problems} unpinned image reference(s)."
echo
echo "Pin each one as <name>:<tag>@sha256:<digest>. Read a digest off the registry"
echo "without pulling the image:"
echo
echo "  docker buildx imagetools inspect <name>:<tag>"
echo
echo "Use the digest of the index it prints, not of a per-platform manifest."

exit 1
