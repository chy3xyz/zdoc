// zdoc default theme behaviour: sidebar highlighting and TOC scroll-spy.
// No framework, no dependencies.

(function () {
  "use strict";

  // Mark the link pointing at the current page in the sidebar.
  var here = location.pathname.replace(/\/index\.html$/, "/");
  here = here.replace(/\/+$/, "") || "/";

  var links = document.querySelectorAll(".sidebar__item, .sidebar__section");
  for (var i = 0; i < links.length; i++) {
    var href = links[i].getAttribute("href") || "";
    var norm = href.replace(/\/index\.html$/, "/").replace(/\/+$/, "") || "/";
    if (norm === here) {
      links[i].classList.add("is-active");
      // A long sidebar starts at the top. The current page should already
      // be in view when the document opens.
      if (links[i].scrollIntoView) {
        links[i].scrollIntoView({ block: "nearest" });
      }
      break;
    }
  }

  // Scroll-spy for the table of contents. Uses the heading anchors the docs
  // theme generates, so it only wires up when they are present.
  var headings = document.querySelectorAll(
    ".doc h1[id], .doc h2[id], .doc h3[id], .doc h4[id], .doc h5[id], .doc h6[id]"
  );
  if (headings.length === 0) return;

  var tocLinks = {};
  var tocAnchors = document.querySelectorAll(".toc a[href^='#']");
  for (var j = 0; j < tocAnchors.length; j++) {
    var raw = tocAnchors[j].getAttribute("href").slice(1);
    try {
      raw = decodeURIComponent(raw);
    } catch (err) {}
    tocLinks[raw] = tocAnchors[j];
  }

  var active = null;

  function setActive(id) {
    if (id === active) return;
    if (active && tocLinks[active]) tocLinks[active].classList.remove("is-active");
    active = id;
    if (tocLinks[id]) {
      tocLinks[id].classList.add("is-active");
      revealOutline(tocLinks[id]);
    }
  }

  // Move the current outline entry into the sticky column. Adjusting
  // scrollTop on that column leaves the article where the reader put it.
  function revealOutline(link) {
    var box = link.closest(".toc");
    if (!box || box.scrollHeight <= box.clientHeight) return;
    var linkRect = link.getBoundingClientRect();
    var boxRect = box.getBoundingClientRect();
    if (linkRect.top < boxRect.top) box.scrollTop -= boxRect.top - linkRect.top;
    else if (linkRect.bottom > boxRect.bottom) {
      box.scrollTop += linkRect.bottom - boxRect.bottom;
    }
  }

  function onScroll() {
    // The last heading that has scrolled past the top of the viewport is the
    // one the reader is currently under.
    var offset = 100;
    var current = headings[0].id;
    for (var k = 0; k < headings.length; k++) {
      if (headings[k].getBoundingClientRect().top - offset <= 0) {
        current = headings[k].id;
      } else {
        break;
      }
    }
    setActive(current);
  }

  var ticking = false;
  window.addEventListener(
    "scroll",
    function () {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(function () {
        onScroll();
        ticking = false;
      });
    },
    { passive: true }
  );

  onScroll();
})();
// ----------------------------------------------------------------- nav drawer
//
// Only meaningful below 800px, where the sidebar is a panel over the content
// rather than a column beside it. Above that the toggle is `display: none`
// and none of this runs, so there is no state to get out of sync.
(function navDrawer() {
  "use strict";

  var toggle = document.getElementById("nav-toggle");
  var scrim = document.getElementById("nav-scrim");
  var sidebar = document.getElementById("sidebar");
  if (!toggle || !scrim || !sidebar) return;

  function setOpen(open) {
    document.body.classList.toggle("nav-open", open);
    toggle.setAttribute("aria-expanded", open ? "true" : "false");
    toggle.setAttribute("aria-label", open ? "Close navigation" : "Open navigation");
    scrim.hidden = !open;
    // Move focus into the panel when it opens, so a keyboard reader is not
    // left behind on a control the drawer has just covered.
    if (open) {
      var first = sidebar.querySelector("a");
      if (first) first.focus();
    }
  }

  toggle.addEventListener("click", function () {
    setOpen(!document.body.classList.contains("nav-open"));
  });

  scrim.addEventListener("click", function () {
    setOpen(false);
  });

  // Following a link inside the drawer should close it, or the reader lands
  // on the next page with the panel still covering it.
  sidebar.addEventListener("click", function (ev) {
    if (ev.target.closest("a")) setOpen(false);
  });

  document.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape" && document.body.classList.contains("nav-open")) {
      setOpen(false);
      toggle.focus();
    }
  });

  // Resizing past the breakpoint leaves `nav-open` set on the body with no
  // toggle visible to clear it, which would hide nothing but confuse the next
  // resize back down.
  window.addEventListener("resize", function () {
    if (window.innerWidth > 800) setOpen(false);
  });
})();

// ------------------------------------------------------------------- search
//
// The index is fetched on the first keystroke rather than on load: a reader
// who never searches never downloads it, and on a large site that file is
// larger than every page put together.
(function search() {
  "use strict";

  var box = document.getElementById("search");
  var input = document.getElementById("search-input");
  var results = document.getElementById("search-results");
  var status = document.getElementById("search-status");
  var meta = document.querySelector('meta[name="zdoc-search-index"]');
  if (!box || !input || !results || !meta) return;

  var index = null;
  var loading = null;
  var rows = [];
  var active = -1;

  function load() {
    if (index) return Promise.resolve(index);
    if (loading) return loading;
    loading = fetch(meta.getAttribute("content"))
      .then(function (r) {
        if (!r.ok) throw new Error("search index: " + r.status);
        return r.json();
      })
      .then(function (data) {
        index = data;
        return data;
      })
      .catch(function (err) {
        // A failed index must not break the page. Search stops offering
        // results, which is far better than an unhandled rejection on every
        // keystroke.
        console.warn(err);
        input.disabled = true;
        input.placeholder = "Search unavailable";
        return null;
      });
    return loading;
  }

  // Byte bigrams, lowercased, packed into one number. This has to agree
  // exactly with `src/docs/Search.zig`: the index is written in Zig and read
  // here, and a disagreement shows up as a search that silently finds nothing.
  function bigrams(text) {
    var bytes = new TextEncoder().encode(text.toLowerCase());
    var out = [];
    for (var i = 0; i + 1 < bytes.length; i++) {
      out.push((bytes[i] << 8) | bytes[i + 1]);
    }
    return out;
  }

  // Records that contain every bigram of the query, best first.
  //
  // Two rules, and both are load-bearing:
  //
  //   - A record must match ALL of the query's known bigrams. Scoring by how
  //     many it matched instead would let a query nobody has ever typed
  //     return results: "zzzqqq" shares a bigram or two with real prose and
  //     would come back with ten pages, which reads as "search is broken".
  //
  //   - At least half the query's bigrams must be in the index at all. A
  //     query that is mostly unknown is either a typo or nonsense, and
  //     answering it from the one common bigram it contains is worse than
  //     answering nothing.
  function rank(query) {
    var grams = bigrams(query);
    if (grams.length === 0) return [];

    var lists = [];
    for (var i = 0; i < grams.length; i++) {
      var list = index.k[grams[i].toString(16)];
      if (list) lists.push(list);
    }
    if (lists.length === 0) return [];
    if (lists.length * 2 < grams.length) return [];

    // Intersect smallest-first: the result can only shrink, so starting with
    // the shortest list does the least work.
    lists.sort(function (a, b) {
      return a.length - b.length;
    });

    var hits = [];
    var shortest = lists[0];
    for (var s = 0; s < shortest.length; s++) {
      var id = shortest[s];
      var inAll = true;
      for (var l = 1; l < lists.length; l++) {
        if (lists[l].indexOf(id) === -1) {
          inAll = false;
          break;
        }
      }
      if (inAll) hits.push(id);
    }

    // A record whose heading is close to the query is more likely to be what
    // the reader meant than one that only mentions it in passing.
    hits.sort(function (a, b) {
      return index.r[a].h.length - index.r[b].h.length;
    });
    return hits.slice(0, 20).map(function (id) {
      return index.r[id];
    });
  }

  var MAX_RESULTS = 20;

  // Renders `text` with the first occurrence of `query` marked.
  //
  // Built from text nodes and a single <mark>, never from an HTML string: the
  // text is the author's prose, and a document can contain anything.
  function highlight(target, text, query) {
    target.textContent = "";
    if (!query) {
      target.textContent = text;
      return;
    }
    var at = text.toLowerCase().indexOf(query.toLowerCase());
    if (at === -1 || query.length < 2) {
      target.textContent = text;
      return;
    }
    target.appendChild(document.createTextNode(text.slice(0, at)));
    var mark = document.createElement("mark");
    mark.textContent = text.slice(at, at + query.length);
    target.appendChild(mark);
    target.appendChild(document.createTextNode(text.slice(at + query.length)));
  }

  function setActive(next) {
    if (active === next) return;
    if (rows[active]) rows[active].removeAttribute("aria-selected");
    active = next;
    if (rows[active]) {
      rows[active].setAttribute("aria-selected", "true");
      // The dropdown is short and the list can be long; without this, arrowing
      // past the fold moves the selection somewhere the reader cannot see.
      rows[active].scrollIntoView({ block: "nearest" });
      input.setAttribute("aria-activedescendant", rows[active].id);
    } else {
      input.removeAttribute("aria-activedescendant");
    }
  }

  function close() {
    results.hidden = true;
    results.innerHTML = "";
    rows = [];
    setActive(-1);
    input.setAttribute("aria-expanded", "false");
    status.textContent = "";
  }

  function show(query) {
    results.innerHTML = "";
    rows = [];
    setActive(-1);

    if (!query) {
      close();
      return;
    }

    var found = rank(query);
    if (found.length === 0) {
      var none = document.createElement("li");
      none.className = "search__empty";
      none.textContent = "No results";
      results.appendChild(none);
    }

    found.forEach(function (row, i) {
      var li = document.createElement("li");
      li.className = "search__result";
      li.id = "search-result-" + i;
      li.setAttribute("role", "option");

      var a = document.createElement("a");
      a.href = row.u + (row.a ? "#" + row.a : "");
      a.tabIndex = -1;

      var title = document.createElement("span");
      title.className = "search__result-title";
      highlight(title, row.h || row.t, query);
      a.appendChild(title);

      if (row.h) {
        var page = document.createElement("span");
        page.className = "search__result-page";
        page.textContent = row.t;
        a.appendChild(page);
      }

      li.appendChild(a);
      results.appendChild(li);
      rows.push(li);
    });

    results.hidden = false;
    input.setAttribute("aria-expanded", "true");
    status.textContent =
      found.length === 1 ? "1 result" : found.length + " results";
  }

  var pending = null;
  input.addEventListener("input", function () {
    var query = input.value.trim();
    if (query.length < 2) {
      close();
      return;
    }
    clearTimeout(pending);
    pending = setTimeout(function () {
      load().then(function (data) {
        if (data) show(query);
      });
    }, 120);
  });

  input.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape") {
      ev.preventDefault();
      input.value = "";
      close();
      input.blur();
      return;
    }
    if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
      if (rows.length === 0) return;
      ev.preventDefault();
      var step = ev.key === "ArrowDown" ? 1 : -1;
      // Wrap, so holding the arrow key cycles rather than sticking at an end.
      var next = (active + step + rows.length) % rows.length;
      setActive(next);
      return;
    }
    if (ev.key === "Enter") {
      if (rows.length === 0) return;
      ev.preventDefault();
      var chosen = rows[active === -1 ? 0 : active];
      window.location.href = chosen.querySelector("a").href;
    }
  });

  // "/" focuses search from anywhere, the way most documentation sites do.
  // A modifier means the reader is typing a shortcut of their own.
  document.addEventListener("keydown", function (ev) {
    if (ev.key !== "/" || ev.ctrlKey || ev.metaKey || ev.altKey) return;
    var tag = document.activeElement && document.activeElement.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
    ev.preventDefault();
    input.focus();
    input.select();
  });

  // The hint is decoration; it should not appear once the reader knows it.
  input.addEventListener("focus", function () {
    box.classList.add("is-focused");
  });
  input.addEventListener("blur", function () {
    box.classList.remove("is-focused");
  });

  document.addEventListener("click", function (ev) {
    if (!box.contains(ev.target)) close();
  });
})();

// ----------------------------------------------------------------- code copy
//
// A button on each fenced block. The host is the figure when the highlighter
// wrapped the pre, and the pre itself otherwise. Position comes from
// `.code-copy-host` in the stylesheet.
(function codeCopy() {
  "use strict";

  function codeText(pre) {
    var lines = pre.querySelectorAll(".code-line");
    if (lines.length) {
      var parts = [];
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].cloneNode(true);
        var nums = line.querySelectorAll(".code-line-no");
        for (var n = 0; n < nums.length; n++) {
          nums[n].parentNode.removeChild(nums[n]);
        }
        parts.push(line.textContent || "");
      }
      return parts.join("\n");
    }
    var clone = pre.cloneNode(true);
    var buttons = clone.querySelectorAll(".code-copy");
    for (var b = 0; b < buttons.length; b++) {
      buttons[b].parentNode.removeChild(buttons[b]);
    }
    return clone.textContent || "";
  }

  function copyWithTextarea(text) {
    var area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try {
      ok = document.execCommand("copy");
    } catch (err) {
      ok = false;
    }
    document.body.removeChild(area);
    return ok;
  }

  function writeClipboard(text, done) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () {});
      return;
    }
    if (copyWithTextarea(text)) done();
  }

  function attach(pre) {
    var parent = pre.parentElement;
    var host = pre;
    if (
      parent &&
      parent.tagName === "FIGURE" &&
      parent.classList.contains("code-block")
    ) {
      host = parent;
    }
    host.classList.add("code-copy-host");

    var code = pre.querySelector("code");
    var lang = "";
    if (code && code.className) lang = code.className.trim().split(/\s+/)[0];
    if (lang && lang !== "mermaid") {
      var label = document.createElement("span");
      label.className = "code-lang";
      label.textContent = lang;
      if (host.tagName === "FIGURE") {
        var caption = host.querySelector("figcaption");
        if (caption) caption.appendChild(label);
        else host.insertBefore(label, host.firstChild);
      } else {
        host.insertBefore(label, host.firstChild);
      }
    }

    var button = document.createElement("button");
    button.type = "button";
    button.className = "code-copy";
    button.textContent = "Copy";
    button.setAttribute("aria-label", "Copy code");
    host.appendChild(button);

    var resetTimer = null;
    button.addEventListener("click", function () {
      writeClipboard(codeText(pre), function () {
        button.textContent = "Copied";
        clearTimeout(resetTimer);
        resetTimer = setTimeout(function () {
          button.textContent = "Copy";
        }, 1500);
      });
    });
  }

  var pres = document.querySelectorAll(".doc pre");
  for (var i = 0; i < pres.length; i++) {
    var pre = pres[i];
    if (pre.classList.contains("mermaid")) continue;
    if (pre.closest(".mermaid")) continue;
    attach(pre);
  }
})();

// --------------------------------------------------------- heading permalinks
(function headingPermalinks() {
  "use strict";

  var headings = document.querySelectorAll(
    ".doc h1[id], .doc h2[id], .doc h3[id], .doc h4[id], .doc h5[id], .doc h6[id]"
  );
  for (var i = 0; i < headings.length; i++) {
    var heading = headings[i];
    if (heading.closest("summary")) continue;
    if (heading.querySelector(".heading-anchor")) continue;
    var id = heading.getAttribute("id");
    if (!id) continue;
    var link = document.createElement("a");
    link.className = "heading-anchor";
    link.href = "#" + encodeURIComponent(id);
    link.setAttribute("aria-label", "Permalink");
    link.textContent = "#";
    heading.appendChild(link);
  }
})();

// ------------------------------------------------------------ manual theme
//
// An inline script in the head may already have set `data-theme` from
// localStorage. This only mirrors that choice onto the toggle, and writes
// the attribute when the reader picks the other mode.
(function themeToggle() {
  "use strict";

  var button = document.getElementById("theme-toggle");
  if (!button) return;

  function effectiveTheme() {
    var theme = document.documentElement.getAttribute("data-theme");
    if (theme === "dark" || theme === "light") return theme;
    if (
      window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches
    ) {
      return "dark";
    }
    return "light";
  }

  function sync() {
    var dark = effectiveTheme() === "dark";
    button.setAttribute("aria-pressed", dark ? "true" : "false");
    button.textContent = dark ? "Light" : "Dark";
    button.setAttribute(
      "aria-label",
      dark ? "Use light theme" : "Use dark theme"
    );
  }

  sync();

  button.addEventListener("click", function () {
    var next = effectiveTheme() === "dark" ? "light" : "dark";
    try {
      localStorage.setItem("zdoc-theme", next);
    } catch (err) {}
    document.documentElement.setAttribute("data-theme", next);
    sync();
  });
})();

// ---------------------------------------------------- outline on a narrow page
//
// The right-hand column is a sticky list on a wide window. Below 1100px the
// stylesheet moves that list above the article, and this folds it so a long
// outline does not push the page down. Without JavaScript the list stays
// expanded.
(function narrowOutline() {
  "use strict";

  var toc = document.getElementById("toc");
  if (!toc || toc.querySelector("details")) return;
  if (!window.matchMedia || !window.matchMedia("(max-width: 1100px)").matches) return;

  var title = toc.querySelector(".toc__title");
  var details = document.createElement("details");
  details.className = "toc__panel";
  if (title) {
    var summary = document.createElement("summary");
    summary.className = title.className;
    summary.textContent = title.textContent;
    title.parentNode.removeChild(title);
    details.appendChild(summary);
  }
  while (toc.firstChild) details.appendChild(toc.firstChild);
  toc.appendChild(details);
})();

// ---------------------------------------------------------- version switch
(function versionSwitch() {
  "use strict";

  var selects = document.querySelectorAll("select.version-switch__select");
  for (var i = 0; i < selects.length; i++) {
    selects[i].addEventListener("change", function () {
      if (this.value) window.location.href = this.value;
    });
  }
})();

// ----------------------------------------------------------- external links
//
// A link that leaves this origin opens in a new tab. Same-site absolute
// URLs stay in this tab. The class is what the stylesheet uses for the mark.
(function externalLinks() {
  "use strict";

  var origin = window.location.origin;
  var links = document.querySelectorAll("a[href]");
  for (var i = 0; i < links.length; i++) {
    var href = links[i].getAttribute("href") || "";
    if (href.indexOf("http://") !== 0 && href.indexOf("https://") !== 0) continue;
    var url;
    try {
      url = new URL(href);
    } catch (err) {
      continue;
    }
    if (url.origin === origin) continue;
    links[i].target = "_blank";
    links[i].rel = "noopener noreferrer";
    links[i].classList.add("external");
  }
})();
