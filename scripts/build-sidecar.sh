#!/bin/sh
set -eu

# Build the exact reviewed llama.cpp revision as a relocatable sidecar.
# Model weights are deliberately not part of the archive.
root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
target=${1:-$(rustc -vV | awk '/^host:/ { print $2 }')}
version_file="$root/runtime/llama.version"
tag=$(sed -n 's/^tag=//p' "$version_file")
revision=$(sed -n 's/^revision=//p' "$version_file")
[ -n "$tag" ] && [ -n "$revision" ] || {
	echo "build-sidecar: invalid $version_file" >&2
	exit 1
}

for tool in git cmake; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "build-sidecar: required tool not found: $tool" >&2
		exit 1
	}
done

case "$target" in
	aarch64-apple-darwin) platform=darwin architecture=arm64 metal=ON ;;
	x86_64-unknown-linux-gnu) platform=linux architecture=x86_64 metal=OFF ;;
	aarch64-unknown-linux-gnu) platform=linux architecture=aarch64 metal=OFF ;;
	*) echo "build-sidecar: unsupported target: $target" >&2; exit 1 ;;
esac

host_platform=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$host_platform/$platform" in
	darwin/darwin|linux/linux) ;;
	*) echo "build-sidecar: target $target requires a $platform build host" >&2; exit 1 ;;
esac
if [ "$platform" = "linux" ]; then
	host_arch=$(uname -m)
	case "$host_arch/$architecture" in
		x86_64/x86_64|aarch64/aarch64|arm64/aarch64) ;;
		*) echo "build-sidecar: Linux cross-compilation is not configured for $target" >&2; exit 1 ;;
	esac
fi

cache_root=${LLAMA_BUILD_CACHE:-"$root/.cache/llama.cpp"}
source_dir="$cache_root/source-$revision"
build_dir="$cache_root/build-$revision-$target"
binary_dir=${LLAMA_BINARY_DIR:-"$root/dist/bin"}
output="$binary_dir/llama-server-$target"
license="$binary_dir/llama.cpp-LICENSE"
recipe=$(
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$root/scripts/build-sidecar.sh"
	else
		shasum -a 256 "$root/scripts/build-sidecar.sh"
	fi | cut -d' ' -f1
)
identity="revision=$revision target=$target recipe=$recipe"
stamp="$output.revision"

mkdir -p "$cache_root" "$binary_dir"
if [ "${LLAMA_FORCE:-0}" != "1" ] &&
	[ -x "$output" ] &&
	[ -f "$stamp" ] &&
	[ -f "$license" ] &&
	[ "$(cat "$stamp")" = "$identity" ]; then
	echo "build-sidecar: $tag ($revision) already built -> $output"
	exit 0
fi

if [ ! -d "$source_dir/.git" ]; then
	mkdir -p "$source_dir"
	git -C "$source_dir" init -q
	git -C "$source_dir" remote add origin https://github.com/ggml-org/llama.cpp.git
	git -C "$source_dir" fetch -q --depth 1 origin "$revision"
	git -C "$source_dir" checkout -q --detach FETCH_HEAD
fi
actual=$(git -C "$source_dir" rev-parse HEAD)
[ "$actual" = "$revision" ] || {
	echo "build-sidecar: source mismatch: expected $revision, found $actual" >&2
	exit 1
}

cmake -E remove_directory "$build_dir/tools/ui/dist"
set -- \
	-S "$source_dir" \
	-B "$build_dir" \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=OFF \
	-DGGML_NATIVE=OFF \
	-DGGML_BLAS=OFF \
	-DGGML_METAL="$metal" \
	-DGGML_METAL_EMBED_LIBRARY=ON \
	-DLLAMA_BUILD_SERVER=ON \
	-DLLAMA_BUILD_TESTS=OFF \
	-DLLAMA_BUILD_TOOLS=ON \
	-DLLAMA_BUILD_EXAMPLES=OFF \
	-DLLAMA_BUILD_APP=OFF \
	-DLLAMA_BUILD_UI=OFF \
	-DLLAMA_USE_PREBUILT_UI=OFF \
	-DLLAMA_OPENSSL=OFF \
	-DLLAMA_SUBPROCESS=OFF
if [ "$platform" = "darwin" ]; then
	set -- "$@" -DCMAKE_OSX_ARCHITECTURES="$architecture" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0
fi
cmake "$@"
build_jobs=${LLAMA_BUILD_JOBS:-2}
case "$build_jobs" in
	''|0|*[!0-9]*) echo "build-sidecar: LLAMA_BUILD_JOBS must be a positive integer" >&2; exit 1 ;;
esac
cmake --build "$build_dir" --config Release --target llama-server --parallel "$build_jobs"

candidate="$build_dir/bin/llama-server"
[ -x "$candidate" ] || {
	echo "build-sidecar: expected executable missing: $candidate" >&2
	exit 1
}
cp "$candidate" "$output"
cp "$source_dir/LICENSE" "$license"
chmod 0755 "$output"

if [ "$platform" = "darwin" ]; then
	if otool -L "$output" | tail -n +2 | grep -E '(@rpath|/opt/|/usr/local/)' >/dev/null; then
		echo "build-sidecar: executable has non-system dynamic dependencies" >&2
		otool -L "$output" >&2
		exit 1
	fi
else
	if ldd "$output" 2>/dev/null | grep -E 'lib(llama|ggml)' >/dev/null; then
		echo "build-sidecar: executable has unbundled llama.cpp libraries" >&2
		ldd "$output" >&2
		exit 1
	fi
fi

printf '%s' "$identity" > "$stamp"
echo "build-sidecar: $tag ($revision) -> $output"
