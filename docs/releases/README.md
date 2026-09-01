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
- No paragraph that a bullet would carry. Aim for 250 words. A release the size
  of v1.7.2 — five areas, a dozen changes — may reach 325; past that the file has
  started explaining rather than listing.
- The reasoning behind a change belongs in its commit message, or on the site
  ([internals](https://hashiru.williamhleucka.com/docs/internals.html), [roadmap](https://hashiru.williamhleucka.com/docs/roadmap.html)).
  Link to it instead of restating it.

`v1.6.0.md` and `v1.7.1.md` are the shape to copy.
