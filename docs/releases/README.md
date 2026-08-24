# Release notes

One file per tag, named exactly as the tag: `v1.6.0.md`.

`.github/workflows/release.yml` looks for `docs/releases/<tag>.md` when it
publishes and uses it as the release body. If the file is missing it falls back
to `--generate-notes`, so a forgotten file delays nothing — it just produces a
commit list instead of prose.

Write the file before tagging, since the tag is what triggers the build.
