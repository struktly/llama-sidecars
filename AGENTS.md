# Working guidance

This public repository owns only reproducible builds of the pinned
[`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp) server executable
used by Struktly.

- Keep product source, private repository names, credentials, model files, and
  user data out of this repository and its release assets.
- Keep preparation manually triggered. A merge must never start a costly build.
- Release assets are immutable. Change `release=` in `runtime/llama.version`
  before preparing a different pin or recipe.
- Never add `Co-Authored-By` or generated-with attribution.
