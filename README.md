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