# 交付物放哪

稿酬承诺的四样东西，各有一个地址。

| 交付 | 地址 | 怎么构建 |
|---|---|---|
| 产品页 | `/product/` | `zdoc site` |
| 博客 | `/blog/` | `zdoc site` |
| 文档 | `/docs/` | `zdoc docs docs --output public/docs --url-prefix /docs` |
| 论文 | `/book/` | `zdoc ebook book --output public/book --url-prefix /book` |

先构建门户，再把文档和论文放进同一个 `public/`。后一次构建不要把输出指到已经有 `index.html` 的目录。
