# Struktly llama.cpp sidecars

Reproducible, immutable builds of the pinned
[`llama-server`](https://github.com/ggml-org/llama.cpp) executable used by
Struktly.

This repository intentionally contains no Struktly product source, credentials,
models, or user data. It contains only the upstream revision pin, portable build
and packaging scripts, tests, and a manually triggered release workflow.

## Targets

- Apple Silicon macOS: `aarch64-apple-darwin`
- x86-64 Linux: `x86_64-unknown-linux-gnu`
- ARM64 Linux: `aarch64-unknown-linux-gnu`

## Release contract

Each release contains one archive and checksum manifest per target. The manifest
records the exact upstream revision, build-recipe hash, target, source repository,
and source commit. Consumers should additionally pin the archive SHA-256 in their
own source tree.

Preparing a release is manual by design. Update `runtime/llama.version`, merge
the reviewed change, then run **Prepare pinned llama.cpp sidecars** from `main`.
A normal push or pull request never starts a native build.

## Local checks

```sh
./scripts/test-artifacts.sh
go run github.com/rhysd/actionlint/cmd/actionlint@latest
```

The binaries are builds of llama.cpp; its upstream license and notices apply to
the resulting executable.
