#!/bin/sh
set -eu

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

grep -F -- "--parallel \"\$build_jobs\"" "$root/scripts/build-sidecar.sh" >/dev/null
grep -F "build_jobs=\${LLAMA_BUILD_JOBS:-2}" "$root/scripts/build-sidecar.sh" >/dev/null
grep -F -- "-DLLAMA_BUILD_IS_DEV=OFF" "$root/scripts/build-sidecar.sh" >/dev/null
grep -F -- 'grep -F "version: ${tag#v}"' "$root/scripts/build-sidecar.sh" >/dev/null
release=$(sed -n 's/^release=//p' "$root/runtime/llama.version")
printf '%s\n' "$release" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

target=aarch64-apple-darwin
binary_dir="$tmp/bin"
assets_dir="$tmp/assets"
mkdir -p "$binary_dir"
printf 'fixture executable\n' > "$binary_dir/llama-server-$target"
printf 'fixture upstream license\n' > "$binary_dir/llama.cpp-LICENSE"
chmod 0755 "$binary_dir/llama-server-$target"
identity=$(LLAMA_BINARY_DIR="$binary_dir" "$root/scripts/artifacts.sh" identity "$target")
printf '%s' "$identity" > "$binary_dir/llama-server-$target.revision"

LLAMA_BINARY_DIR="$binary_dir" GITHUB_SHA=fixture "$root/scripts/artifacts.sh" package "$target" "$assets_dir"
LLAMA_BINARY_DIR="$binary_dir" GITHUB_SHA=fixture "$root/scripts/artifacts.sh" verify "$target" "$assets_dir"
if LLAMA_BINARY_DIR="$binary_dir" GITHUB_SHA=other "$root/scripts/artifacts.sh" verify "$target" "$assets_dir" >/dev/null 2>&1; then
	echo "test-artifacts: wrong source revision was accepted" >&2
	exit 1
fi

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
  "release view $SIDECAR_TEST_RELEASE -R $SIDECAR_TEST_REPOSITORY") exit 0 ;;
  "release view $SIDECAR_TEST_RELEASE -R $SIDECAR_TEST_REPOSITORY --json targetCommitish,isDraft,assets -q "*)
    printf '%s %s %s\n' "$SIDECAR_TEST_REVISION" "${SIDECAR_TEST_DRAFT:-true}" "${SIDECAR_TEST_ASSETS:-0}"
    ;;
  "release delete $SIDECAR_TEST_RELEASE -R $SIDECAR_TEST_REPOSITORY --yes") echo "delete" >> "$SIDECAR_TEST_LOG" ;;
  "release create $SIDECAR_TEST_RELEASE -R $SIDECAR_TEST_REPOSITORY --draft --target "*) echo "create $*" >> "$SIDECAR_TEST_LOG" ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$tmp/bin/gh"
SIDECAR_TEST_RELEASE=$(sed -n 's/^release=//p' "$root/runtime/llama.version")
export SIDECAR_TEST_RELEASE
export SIDECAR_TEST_REPOSITORY=struktly/llama-sidecars
export SIDECAR_TEST_REVISION=1111111111111111111111111111111111111111
PATH="$tmp/bin:$PATH"
export PATH
export SIDECAR_TEST_LOG="$tmp/gh.log"
: > "$SIDECAR_TEST_LOG"
GITHUB_SHA="$SIDECAR_TEST_REVISION" "$root/scripts/artifacts.sh" ensure-release
[ ! -s "$SIDECAR_TEST_LOG" ] || { echo "test-artifacts: a draft at the current revision was touched" >&2; exit 1; }
# An empty draft from an earlier commit is recreated at this one.
other=2222222222222222222222222222222222222222
GITHUB_SHA="$other" "$root/scripts/artifacts.sh" ensure-release 2>/dev/null
grep -qx "delete" "$SIDECAR_TEST_LOG" && grep -q "create .* --target $other " "$SIDECAR_TEST_LOG" || {
	echo "test-artifacts: a stale empty draft was not recreated at the current revision" >&2
	exit 1
}
# A published release, or a draft holding binaries, stays immutable.
if SIDECAR_TEST_DRAFT=false GITHUB_SHA="$other" "$root/scripts/artifacts.sh" ensure-release >/dev/null 2>&1; then
	echo "test-artifacts: a published release accepted a different source revision" >&2
	exit 1
fi
if SIDECAR_TEST_ASSETS=3 GITHUB_SHA="$other" "$root/scripts/artifacts.sh" ensure-release >/dev/null 2>&1; then
	echo "test-artifacts: a draft holding binaries accepted a different source revision" >&2
	exit 1
fi

printf 'corrupt' >> "$assets_dir/llama-server-$target.tar.gz"
if LLAMA_BINARY_DIR="$binary_dir" "$root/scripts/artifacts.sh" verify "$target" "$assets_dir" >/dev/null 2>&1; then
	echo "test-artifacts: corrupted archive was accepted" >&2
	exit 1
fi

echo "test-artifacts: passed"
