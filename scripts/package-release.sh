#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir="$repo_root/dist"
requested_version=""

usage() {
  cat <<'EOF'
usage: scripts/package-release.sh [--version <vX.Y.Z|X.Y.Z>] [--output <dir>]

Build every release target, assemble one archive per target and write
SHA256SUMS.

Windows targets are deliberately absent: tuizr's Terminal is POSIX-only and
does not compile for windows-gnu. See .github/workflows/ci.yml.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      requested_version=${2:-}
      shift 2
      ;;
    --output)
      output_dir=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$repo_root"
package_version=$(awk -F'"' '/^[[:space:]]*\.version = "/ { print $2; exit }' build.zig.zon)
version=${requested_version#v}
if [[ -z "$version" ]]; then
  version=$package_version
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release version must be X.Y.Z or vX.Y.Z, got: ${requested_version:-<empty>}" >&2
  exit 1
fi

# The tag is not authoritative on its own; build.zig.zon is. A mismatch means
# the version bump was forgotten, which would ship mislabelled binaries.
if [[ "$version" != "$package_version" ]]; then
  echo "release version $version does not match build.zig.zon version $package_version" >&2
  exit 1
fi

output_dir=$(mkdir -p "$output_dir" && cd "$output_dir" && pwd)
find "$output_dir" -mindepth 1 -maxdepth 1 -type f -delete

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

targets=(
  x86_64-linux-gnu
  aarch64-linux-gnu
  x86_64-macos
  aarch64-macos
)

for target in "${targets[@]}"; do
  echo "==> Building $target"
  rm -rf zig-out
  zig build -Dtarget="$target" -Doptimize=ReleaseSafe --summary all

  if [[ ! -f zig-out/bin/omp-zig ]]; then
    echo "zig build produced no zig-out/bin/omp-zig for $target" >&2
    exit 1
  fi

  archive_root="omp-zig-$version-$target"
  stage="$work_dir/$archive_root"
  mkdir -p "$stage/bin"
  cp -a zig-out/bin/omp-zig "$stage/bin/omp-zig"
  cp README.md "$stage/"

  # Fixed sort order, timestamps and ownership keep the archive byte-identical
  # across runs, so a rebuild of the same commit reproduces the same checksum.
  archive="$output_dir/$archive_root.tar.gz"
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -C "$work_dir" -cf - "$archive_root" | gzip -n >"$archive"
  tar -tzf "$archive" >/dev/null
done

(
  cd "$output_dir"
  find . -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' \
    | LC_ALL=C sort \
    | xargs sha256sum >SHA256SUMS
)

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Release assets"
    echo
    echo '```'
    cat "$output_dir/SHA256SUMS"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi

echo "==> Release assets"
(cd "$output_dir" && find . -mindepth 1 -maxdepth 1 -type f -printf '%f\t%s bytes\n' | LC_ALL=C sort)
