# Release notes

One file per tag, named exactly as the tag: `v1.6.0.md`.

`.github/workflows/release.yml` looks for `docs/releases/<tag>.md` when it
publishes and uses it as the release body. If the file is missing it falls back
to `--generate-notes`, so a forgotten file delays nothing — it just produces a
commit list instead of prose.

Write the file before tagging, since the tag is what triggers the build.

## Style

Bullets, not prose. A reader wants to know whether an update affects them, so
the file answers that and stops:

- A one-line header sentence: what kind of release this is.
- `##` sections grouping bullets. One bullet per change, one or two lines each —
  what changed and, where it isn't obvious, why.
- An `## Upgrading` section saying what to run and what lands when.
- No paragraph that a bullet would carry. Keep the whole file under ~250 words;
  the reasoning behind a change belongs in its commit message and in
  `docs/internals.md`, both of which the notes can point at.

`v1.6.0.md` and `v1.7.1.md` are the shape to copy. `v1.7.2.md` is four times
that length and is the thing to avoid.
