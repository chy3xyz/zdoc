<h1 align="center">zdoc</h1>
<h3 align="center"><em>Turn a folder of Markdown files into a documentation website</em></h3>

`zdoc` is a fork of [Zine](https://github.com/kristoff-it/zine), a fast static
site generator written in Zig. It adds a documentation mode built around one
idea: the documentation you already have should build without being rewritten.

```bash
zdoc docs docs
```

That is the whole setup. No config file, no layout files, no CSS. Point it at a
directory of Markdown and it produces a site with a sidebar derived from the
directory tree, a table of contents on every page, syntax highlighting, task
lists and diagrams.

## Install

Download a prebuilt binary for Linux (x86_64 or ARM64), macOS (Apple Silicon) or
Windows from the [releases page](https://github.com/chy3xyz/zdoc/releases),
or build from source:

```bash
zig build -Doptimize=fast
```

The Linux builds are statically linked against musl, so they run on any glibc
or musl system without extra dependencies.

## Using it

```bash
# Build a documentation site
zdoc docs docs

# Choose the output directory and the site title
zdoc docs docs --output public --title "My Project"

# Render diagrams without network access
zdoc docs docs --mermaid mermaid.esm.min.mjs
```

The directory you point at becomes the site root: `README.md` or `index.md` at
the top level becomes `/`, and subdirectories become nested sections.

## What it handles

Documents written for GitHub usually trip static site generators up. `zdoc`
treats those as ordinary rather than as errors:

- **Markdown as people write it.** `.md` files, no frontmatter required. A page's
  title comes from its first `#` heading.
- **GitHub-compatible anchors.** Heading ids are generated exactly as GitHub
  generates them, so the `#anchor` links already in your documents keep working.
- **Links that leave the docs tree.** Documentation routinely points at files
  outside it — `../AGENTS.md`, `../examples/`. Those links are reported as
  warnings and emitted exactly as written, instead of failing the build.
- **Real-world Markdown.** Skipped heading levels, raw HTML, reference-style
  links, task lists and Mermaid diagrams all render.

## For AI agents

If you are editing a repository whose documentation is built with `zdoc`, two
things are worth knowing before you change anything.

**There is no configuration file, and adding one is the wrong move.** The
sidebar comes from the directory tree, the theme is built in, and frontmatter
is optional. A `zine.ziggy` in a docs directory, a hand-written layout or a
stylesheet dropped next to the Markdown are all ignored — and if you were
reaching for them, the thing you wanted is already expressible.

Build and read the report:

```bash
zdoc docs docs --output public --force
```

The summary is the feedback loop. Anything it lists is a real problem in the
document — a link that no longer resolves, a frontmatter field it could not
read. Documentation mode never fails the build over those, so they are easy to
miss if you only check the exit code. For a check that *does* fail:

```bash
zdoc docs docs --output public --force --strict
```

`--strict` exits non-zero when a link does not resolve, while still writing the
site so you can look at it. That is the one to use in a check.

What the vocabulary is, so you use the existing mechanism rather than
inventing one:

| Write this | To do this |
|---|---|
| `01-guide/`, `02-api/` | Order sections without changing their URLs |
| `order: 2` in a section's index page | Same, when renaming would break links |
| `exclude: true` in a section's index page | Keep a section out of the site entirely |
| `hidden: true` | Keep a page off the sidebar but still published |
| `::: tip` … `:::` | A callout — also `warning`, `danger`, `info` |
| `---` frontmatter with `title:` / `description:` | Override what is inferred |

The distinction between `exclude` and `hidden` is the one that matters:
`exclude` means "not published" (no HTML, no sitemap entry, no search result),
`hidden` means "published, just not in the sidebar".

Two things that look like defects and are not:

- **A page's title comes from its first `#` heading**, so adding a heading at
  the top of a file changes its title. That is intended.
- **Links that point outside the docs tree** (`../AGENTS.md`, `../examples/`)
  are reported and then emitted with the target the author wrote. They are not
  resolved, because the published site has a different root than the
  repository does, so there is no page for them to resolve to. If you need
  such a link to work on the site, the file has to be inside the docs
  directory.

If a document looks wrong in the output, build it and read the warnings before
changing the tool — in a documentation tree, by far the most common cause is a
link in the source that no longer points at anything.

## Blog mode

Zine's original behaviour is untouched and still available:

```bash
zdoc release   # build a site from a zine.ziggy config
zdoc           # start the development server
```

Blog mode keeps Zine's `.smd` dialect, its frontmatter requirements and its
`zine.ziggy` config file.

## Releases

See the [releases page](https://github.com/chy3xyz/zdoc/releases) for
prebuilt binaries and their SHA-256 checksums.

## Feedback

Issues and discussions are enabled, and they answer different questions:

- **[Report a bug or request a feature](https://github.com/chy3xyz/zdoc/issues/new/choose)**
  — something does not work as expected, or you want something new. The
  templates ask for the command you ran and a minimal document to reproduce
  with, which is usually enough to act on.
- **[Ask a question or start a conversation](https://github.com/chy3xyz/zdoc/discussions)**
  — you are not sure how to do something, or want to agree on a direction
  before doing it.

The most useful feedback, if you have run this against your own documentation,
is a document that did not survive the import. Documentation mode reports
those as warnings rather than failing, so they are easy to miss:

```bash
zdoc docs docs
# ... reports how many warnings, and which links could not be resolved
```

Anything listed there is a candidate for improvement.

## Contributing

This is a fork of Zine. Please start a [discussion](https://github.com/chy3xyz/zdoc/discussions)
before taking on anything substantial, so the direction can be agreed first.