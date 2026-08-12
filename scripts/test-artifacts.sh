#!/bin/sh
set -eu

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

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

printf 'corrupt' >> "$assets_dir/llama-server-$target.tar.gz"
if LLAMA_BINARY_DIR="$binary_dir" "$root/scripts/artifacts.sh" verify "$target" "$assets_dir" >/dev/null 2>&1; then
	echo "test-artifacts: corrupted archive was accepted" >&2
	exit 1
fi

echo "test-artifacts: passed"
