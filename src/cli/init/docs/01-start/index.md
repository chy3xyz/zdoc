# 接到站点上

一篇稿子进站，只做三件事。

1. 正文放进 `content/`，一页一个文件。
2. 版式放进 `layouts/`。门户的结构在 `layouts/index.shtml`。
3. 在放着 `zine.ziggy` 的目录里运行 `zdoc`，先看，再构建。

文档和论文不走这一套模板。它们是旁边的 Markdown 目录，用 `zdoc docs` 和 `zdoc ebook` 构建到 `public/docs` 和 `public/book`。
