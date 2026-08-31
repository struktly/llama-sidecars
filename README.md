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

This repository versions its reproducible packaging contract with stable
[Semantic Versioning](https://semver.org/). The upstream llama.cpp tag and
commit remain separate pins; failed preparation attempts do not become release
suffixes.

Each release contains one archive and checksum manifest per target. The manifest
records the exact upstream revision, build-recipe hash, target, source repository,
and source commit. Consumers should additionally pin the archive SHA-256 in their
own source tree.

[release-please](https://github.com/googleapis/release-please) proposes the
`release=` bump in `runtime/llama.version` as a standing pull request, built
from conventional commit messages, and tags + drafts a GitHub Release once
that PR is merged. Preparing the actual binaries stays manual by design:
merging the release-please PR never runs **Prepare pinned llama.cpp
sidecars** — dispatch that workflow from `main` yourself when you want to
promote the draft release. A normal push or pull request never starts a
native build.

## Local checks

```sh
./scripts/test-artifacts.sh
go run github.com/rhysd/actionlint/cmd/actionlint@latest
```

The binaries are builds of llama.cpp; its upstream license and notices apply to
the resulting executable.
