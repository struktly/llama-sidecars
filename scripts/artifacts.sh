#!/bin/sh
set -eu

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
repository=${LLAMA_SIDECAR_REPOSITORY:-${GITHUB_REPOSITORY:-struktly/llama-sidecars}}
binaries_dir=${LLAMA_BINARY_DIR:-"$root/dist/bin"}

fail() {
	printf 'artifacts: %s\n' "$1" >&2
	exit 1
}

require_tools() {
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
	done
}

hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

load_identity() {
	target=$1
	case "$target" in
		aarch64-apple-darwin|x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu) ;;
		*) fail "unsupported target: $target" ;;
	esac
	tag=$(sed -n 's/^tag=//p' "$root/runtime/llama.version")
	revision=$(sed -n 's/^revision=//p' "$root/runtime/llama.version")
	release=$(sed -n 's/^release=//p' "$root/runtime/llama.version")
	[ -n "$tag" ] && [ -n "$revision" ] && [ -n "$release" ] || fail "invalid runtime/llama.version"
	printf '%s\n' "$release" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
		fail "release must be a stable semantic version"
	recipe=$(hash_file "$root/scripts/build-sidecar.sh")
	identity="revision=$revision target=$target recipe=$recipe"
	binary="llama-server-$target"
	stamp="$binary.revision"
	license="llama.cpp-LICENSE"
	archive="$binary.tar.gz"
	manifest="$archive.sha256"
}

validate_installed() {
	[ -x "$binaries_dir/$binary" ] || fail "executable is missing: $binaries_dir/$binary"
	[ -f "$binaries_dir/$stamp" ] || fail "identity is missing: $binaries_dir/$stamp"
	[ -f "$binaries_dir/$license" ] || fail "upstream license is missing: $binaries_dir/$license"
	[ "$(cat "$binaries_dir/$stamp")" = "$identity" ] || fail "identity does not match the pin and recipe"
}

identity_command() {
	load_identity "${1:?usage: artifacts.sh identity TARGET}"
	printf '%s\n' "$identity"
}

package_sidecar() {
	target=${1:?usage: artifacts.sh package TARGET OUTPUT_DIR}
	output_dir=${2:?usage: artifacts.sh package TARGET OUTPUT_DIR}
	load_identity "$target"
	require_tools tar
	validate_installed
	mkdir -p "$output_dir"
	[ ! -e "$output_dir/$archive" ] || fail "asset already exists: $output_dir/$archive"
	[ ! -e "$output_dir/$manifest" ] || fail "asset already exists: $output_dir/$manifest"
	tar -czf "$output_dir/$archive" -C "$binaries_dir" "$binary" "$stamp" "$license"
	{
		printf '%s  %s\n' "$(hash_file "$output_dir/$archive")" "$archive"
		printf 'binary_sha256=%s\n' "$(hash_file "$binaries_dir/$binary")"
		printf 'identity=%s\n' "$identity"
		printf 'llama_tag=%s\n' "$tag"
		printf 'llama_revision=%s\n' "$revision"
		printf 'release=%s\n' "$release"
		printf 'source_repository=%s\n' "$repository"
		printf 'source_revision=%s\n' "${GITHUB_SHA:-local}"
	} > "$output_dir/$manifest"
}

verify_files() {
	target=${1:?usage: artifacts.sh verify TARGET DIRECTORY}
	directory=${2:?usage: artifacts.sh verify TARGET DIRECTORY}
	load_identity "$target"
	[ -f "$directory/$archive" ] && [ -f "$directory/$manifest" ] || fail "archive or manifest is missing for $target"
	expected_hash=$(awk 'NR == 1 { print $1 }' "$directory/$manifest")
	expected_name=$(awk 'NR == 1 { print $2 }' "$directory/$manifest")
	[ "$expected_name" = "$archive" ] || fail "manifest names the wrong archive"
	[ "$expected_hash" = "$(hash_file "$directory/$archive")" ] || fail "archive checksum mismatch"
	grep -Fx "identity=$identity" "$directory/$manifest" >/dev/null || fail "manifest identity mismatch"
	grep -Fx "llama_tag=$tag" "$directory/$manifest" >/dev/null || fail "manifest tag mismatch"
	grep -Fx "llama_revision=$revision" "$directory/$manifest" >/dev/null || fail "manifest revision mismatch"
	grep -Fx "release=$release" "$directory/$manifest" >/dev/null || fail "manifest release mismatch"
	grep -Fx "source_repository=$repository" "$directory/$manifest" >/dev/null || fail "manifest repository mismatch"
	if [ -n "${GITHUB_SHA:-}" ]; then
		grep -Fx "source_revision=$GITHUB_SHA" "$directory/$manifest" >/dev/null || fail "manifest source revision mismatch"
	fi

	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM
	tar -tzf "$directory/$archive" | LC_ALL=C sort > "$tmp/actual-files"
	printf '%s\n%s\n%s\n' "$binary" "$stamp" "$license" | LC_ALL=C sort > "$tmp/expected-files"
	cmp "$tmp/actual-files" "$tmp/expected-files" >/dev/null || fail "archive contains unexpected files"
	mkdir -p "$tmp/extract"
	tar -xzf "$directory/$archive" -C "$tmp/extract"
	[ -f "$tmp/extract/$binary" ] && [ ! -L "$tmp/extract/$binary" ] || fail "executable is not a regular file"
	[ -f "$tmp/extract/$stamp" ] && [ ! -L "$tmp/extract/$stamp" ] || fail "identity is not a regular file"
	[ -f "$tmp/extract/$license" ] && [ ! -L "$tmp/extract/$license" ] || fail "upstream license is not a regular file"
	grep -Fx "binary_sha256=$(hash_file "$tmp/extract/$binary")" "$directory/$manifest" >/dev/null || fail "binary checksum mismatch"
	[ "$(cat "$tmp/extract/$stamp")" = "$identity" ] || fail "archive identity mismatch"
	rm -rf "$tmp"
	trap - EXIT INT TERM
}

ensure_release() {
	require_tools gh
	release=$(sed -n 's/^release=//p' "$root/runtime/llama.version")
	[ -n "$release" ] || fail "invalid runtime/llama.version"
	if gh release view "$release" -R "$repository" >/dev/null 2>&1; then
		if [ -n "${GITHUB_SHA:-}" ]; then
			release_revision=$(gh release view "$release" -R "$repository" --json targetCommitish -q .targetCommitish) ||
				fail "could not resolve existing release target $release"
			[ "$release_revision" = "$GITHUB_SHA" ] || fail "release $release points to a different source revision; bump release= before rebuilding"
		fi
		return 0
	fi
	gh release create "$release" -R "$repository" --draft \
		--target "${GITHUB_SHA:-main}" --title "llama.cpp sidecars $release" \
		--notes "Immutable llama.cpp server builds. See the attached checksum manifests for source and build identity."
}

restore_sidecar() {
	target=${1:?usage: artifacts.sh restore TARGET}
	load_identity "$target"
	require_tools gh tar
	assets=$(gh release view "$release" -R "$repository" --json assets --jq '.assets[].name') ||
		fail "could not inspect release assets for $release"
	has_archive=false
	has_manifest=false
	printf '%s\n' "$assets" | grep -Fx "$archive" >/dev/null && has_archive=true
	printf '%s\n' "$assets" | grep -Fx "$manifest" >/dev/null && has_manifest=true
	if [ "$has_archive" = false ] && [ "$has_manifest" = false ]; then
		printf 'artifacts: no prepared sidecar for %s in %s\n' "$target" "$release" >&2
		return 2
	fi
	[ "$has_archive" = true ] && [ "$has_manifest" = true ] || fail "release assets are incomplete for $target"
	tmp=$(mktemp -d)
	cleanup_tmp() { rm -rf "$tmp"; }
	trap cleanup_tmp EXIT INT TERM
	gh release download "$release" -R "$repository" --dir "$tmp" --clobber \
		--pattern "$archive" --pattern "$manifest"
	verify_files "$target" "$tmp"
	mkdir -p "$binaries_dir"
	tar -xzf "$tmp/$archive" -C "$binaries_dir"
	chmod 0755 "$binaries_dir/$binary"
	validate_installed
	cleanup_tmp
	trap - EXIT INT TERM
}

publish_sidecar() {
	target=${1:?usage: artifacts.sh publish TARGET OUTPUT_DIR}
	output_dir=${2:?usage: artifacts.sh publish TARGET OUTPUT_DIR}
	load_identity "$target"
	ensure_release
	assets=$(gh release view "$release" -R "$repository" --json assets --jq '.assets[].name')
	if printf '%s\n' "$assets" | grep -Fx "$archive" >/dev/null ||
		printf '%s\n' "$assets" | grep -Fx "$manifest" >/dev/null; then
		fail "immutable sidecar asset already exists for $target"
	fi
	package_sidecar "$target" "$output_dir"
	verify_files "$target" "$output_dir"
	gh release upload "$release" -R "$repository" "$output_dir/$archive" "$output_dir/$manifest"
}

publish_release() {
	require_tools gh
	ensure_release
	for target in aarch64-apple-darwin x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
		load_identity "$target"
		tmp=$(mktemp -d)
		gh release download "$release" -R "$repository" --dir "$tmp" --clobber \
			--pattern "$archive" --pattern "$manifest"
		verify_files "$target" "$tmp"
		rm -rf "$tmp"
	done
	gh release edit "$release" -R "$repository" --draft=false --prerelease=false --latest
}

case "${1:-}" in
	identity) shift; identity_command "$@" ;;
	package) shift; package_sidecar "$@" ;;
	verify) shift; verify_files "$@" ;;
	ensure-release) shift; ensure_release "$@" ;;
	restore) shift; restore_sidecar "$@" ;;
	publish) shift; publish_sidecar "$@" ;;
	publish-release) shift; publish_release "$@" ;;
	*)
		cat >&2 <<'EOF'
usage: scripts/artifacts.sh <command> [arguments]

  identity TARGET
  package TARGET OUTPUT_DIR
  verify TARGET DIRECTORY
  ensure-release
  restore TARGET
  publish TARGET OUTPUT_DIR
  publish-release
EOF
		exit 1
		;;
esac
