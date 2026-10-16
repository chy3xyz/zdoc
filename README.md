<h1 align="center">zdoc</h1>
<h3 align="center">The docs you already wrote, as a site people finish reading.</h3>

`zdoc` takes a folder of Markdown and builds a documentation website. The sidebar comes from the directory tree. The title of a page comes from its first heading. Search, a table of contents, syntax highlighting and the date of the last commit come with it.

There is no config file.

```bash
zdoc docs
```

That is the whole setup. When a `docs/` directory exists it is the tree; otherwise the current directory is. Pass a path to use a different one: `zdoc docs ~/projects/myapp/docs`.

`README.md` or `index.md` at the top of the folder becomes the homepage. Every subdirectory becomes a section, in the order you named it: `01-guide/` before `02-api/`, without changing the URL.

It is a fork of [Zine](https://github.com/kristoff-it/zine), a static site generator written in Zig. Documentation and books stay Markdown with no config file. An official site or a blog uses `.smd` pages and `.shtml` templates, so the layout lives in the project.

## Install

Prebuilt binaries for Linux (x86_64 and ARM64), macOS (Apple Silicon) and Windows are on the [releases page](https://github.com/chy3xyz/zdoc/releases), with SHA-256 checksums. The Linux builds are statically linked against musl, so they run on glibc or musl with nothing else installed.

Or build it:

```bash
zig build -Doptimize=fast
```

## Use it

```bash
zdoc docs
zdoc docs --output public --title "My Project"
zdoc docs --mermaid mermaid.esm.min.mjs   # diagrams, no network
```

Four commands, one for each kind of site:

| Command | Pages | What you edit |
|---|---|---|
| `zdoc site` | `.smd` | `.shtml` templates in the project |
| `zdoc blog` | `.smd` | the same, plus dates and a feed |
| `zdoc docs` | `.md` | the Markdown tree |
| `zdoc ebook` | `.md` | the Markdown tree |

Open `public/` afterwards. The build also prints the links it could not resolve.

Start an official site, with a landing page, a product page, a blog, and Markdown trees for docs and a paper:

```bash
zdoc init studio
cd studio
zdoc
```

### A book

The same folder can be a book. The root `index.md` or `README.md` is the cover. Every other page is a chapter. Previous and Next walk the same sequence as the Contents menu. There is no page outline.

Reading order is depth-first, by filename. `01-` comes before `02-`, and a file and a directory at the same level share that sequence. The pages inside a directory are read before the next chapter. Given this tree:

```text
index.md
01-departure.md
02-crossing/index.md
02-crossing/reef.md
03-harbor.md
```

the sequence is the cover, `01-departure`, `02-crossing`, `reef`, `03-harbor`. Previous on `03-harbor` is `reef`, the last page of the section before it, not the section index. The prefix stays in the URL. `order:` overrides the filename when a rename would break a link. The heading is the title, not the sort key.

```bash
zdoc ebook
zdoc ebook path/to/chapters --title "夜航"
```

The name in the header is `--title`, or the directory name if you omit it. It is not the cover heading. A documentation site can still use the book layout for one page, by writing `layout: ebook` in that page's frontmatter.

A link the build cannot resolve is a warning, not a failed build: a tree full of `../AGENTS.md` links should still publish. When a check should fail on a dead link and still leave the site on disk:

```bash
zdoc docs --output public --force --strict
```

### A front page

Most folders do not need one. The top `README.md` is already the homepage, rendered as a document. When the root page should introduce the project instead, say so in its frontmatter:

```yaml
---
layout: home
hero:
  name: zdoc
  text: A folder of Markdown. A site.
  tagline: The sidebar is the directory tree.
  actions:
    - theme: brand
      text: Start reading
      link: /guide/
features:
  - title: No config file
    details: Point it at a directory.
---
```

The first action is the filled button. Everything under the frontmatter is still rendered, under the features.

## What it already understands

Docs written for GitHub usually have to be rewritten before another tool will accept them. `zdoc` treats that Markdown as the normal case.

- **No frontmatter required.** A page's title is its first `#` heading. Add `title:` or `description:` only when you want to override that.
- **Anchors match GitHub.** Existing `#anchor` links keep working.
- **Links that leave the tree stay written.** `../examples/` is reported, then emitted as the author wrote it. The build does not fail, and it does not pretend the file is a page on the site.
- **The messy stuff renders.** Skipped heading levels, raw HTML, reference-style links, task lists, `::: tip` callouts, Mermaid diagrams.
- **Dates come from git.** Each page shows its last commit, and `sitemap.xml` uses the same date as `<lastmod>`. A folder that is not a repository simply has no date.

| Write this | To do this |
|---|---|
| `01-guide/`, `02-api/` | Order sections without changing their URLs |
| `order: 2` on a section's index page | Same thing, when renaming would break links |
| `exclude: true` on a section's index page | Leave the section out of the site entirely |
| `hidden: true` | Publish the page, and keep it out of the sidebar |
| `::: tip` … `:::` | A callout. Also `warning`, `danger`, `info` |

`exclude` means not published: no HTML, no sitemap entry, no search hit. `hidden` means published, just not in the sidebar.

## For AI agents

Use the command that matches the site. Documentation and books are a Markdown tree plus the frontmatter in the table above. An official site or a blog is a `zine.ziggy` plus `.smd` pages and `.shtml` layouts that you edit.

Pick the command from the shape of the site:

| Site | Command | Format |
|---|---|---|
| Official site, templates you edit | `zdoc site [dir]` | `.smd` pages, `.shtml` layouts, `zine.ziggy` |
| Blog: dated posts and a feed | `zdoc blog [dir]` | the same |
| Documentation: sidebar, outline, search | `zdoc docs [dir]` | `.md`, no config file |
| Book: cover, Contents, Previous and Next | `zdoc ebook [dir]` | `.md`, no config file |

`zdoc docs` and `zdoc ebook` default to `docs/` when that directory exists, otherwise the current directory. `zdoc site` defaults to `site/` when `site/zine.ziggy` exists, and `zdoc blog` defaults to `blog/` the same way. Output defaults to `public/` next to where you ran the command.

For `docs` and `ebook`, do not add a config file. A `zine.ziggy` next to that Markdown, a hand-written layout, or a stylesheet dropped beside it are ignored. For `site` and `blog`, `zine.ziggy` and the `.shtml` layouts are the project: that is where template work happens. `zdoc` with no subcommand is the development server for those two.

```bash
zdoc ebook path/to/chapters --output public --title "Book Title" --force
zdoc docs --output public --force --strict
```

`--force` replaces a `public/` that already holds other files. `--strict` makes an unresolved link fail the build after the site is written. Without `--strict` that link is a warning, the exit code is still success, and the warning is the report. Read it before editing the tool or the page.

Write pages like this:

- One Markdown file is one page. Its title is the first `#` heading. Add frontmatter only for a field in the table above.
- `index.md` or `README.md` at the root is the homepage. For a book it is the cover: it is not an entry in Contents, and the header links back to it. The header text is `--title`, or the directory name, not that heading.
- A subdirectory is a section. Its `index.md` or `README.md` is the section page. The other files are pages under it.
- Name directories and, for a book, files `01-`, `02-`, `10-` when you care about order. The prefix is part of the URL. Do not strip it and do not add a redirect.
- A book is one depth-first sequence. Files and directories at the same level are ordered together by filename, and the pages inside a directory come before the next chapter. Previous on the chapter after a section is that section's last page.
- A documentation sidebar lists directories first, then pages. A page without `order` is sorted by its heading, so a `01-` prefix on a file does not move it. Put the prefix on the directory, or set `order:`.
- `order:` is an integer. Pages that set it sort before pages that do not. Use it instead of renaming when the URL is already published.
- `hidden: true` publishes the page and omits it from the menu, so it is also absent from a book's Previous and Next. `exclude: true` on a section index drops that section from the site: no HTML, no sitemap entry, no search hit.
- `layout: home` with `hero` and `features` is a landing page. `layout: ebook` on a single documentation page uses the book layout there. `zdoc ebook` is what makes the whole tree a book.
- A link that leaves the tree, such as `../AGENTS.md`, is reported and emitted unchanged. The site root is the content directory, not the repository. Move the file inside the tree if it should be a page.
- Git supplies the date on each page and in `sitemap.xml`. A directory that is not a repository has no date. Do not invent one in the Markdown.

Check a book by building it and walking Previous from the last chapter back to the cover. Contents and Previous/Next are the same sequence. If a page looks wrong, read the warnings first. The usual cause is a link that no longer points at anything, or a heading that changed the title.

## Official site and blog

`zdoc init` writes that project: a landing page, a product page and a blog in `.smd` / `.shtml`, plus `docs/` and `book/` for the other two commands. `zdoc site` and `zdoc blog` build from a `zine.ziggy`. Layouts are `.shtml` and live next to the content, so changing the homepage structure is an edit to a template and another build.

```bash
zdoc site          # site/ when site/zine.ziggy exists, else the current directory
zdoc blog          # blog/ the same way
zdoc               # development server, from the directory that holds zine.ziggy
```

`zdoc release` is the previous name of `zdoc blog`. It still builds the current directory and does not look for `blog/`. Documentation and books do not use any of this.

## Feedback

- **[A bug, or something you want](https://github.com/chy3xyz/zdoc/issues/new/choose).** The templates ask for the command you ran and a minimal document. That is usually enough.
- **[A question, or a direction to agree on](https://github.com/chy3xyz/zdoc/discussions).**

The most useful report is a document of yours that did not survive the import. Run `zdoc docs` on it and include the warnings.

This is a fork of Zine. Please start a [discussion](https://github.com/chy3xyz/zdoc/discussions) before taking on anything substantial.
