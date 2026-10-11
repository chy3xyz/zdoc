// zdoc default theme behaviour: sidebar highlighting and TOC scroll-spy.
// No framework, no dependencies.

(function () {
  "use strict";

  // Mark the link pointing at the current page in the sidebar.
  var here = location.pathname.replace(/\/index\.html$/, "/");
  here = here.replace(/\/+$/, "") || "/";

  var links = document.querySelectorAll(".sidebar__link");
  for (var i = 0; i < links.length; i++) {
    var href = links[i].getAttribute("href") || "";
    var norm = href.replace(/\/index\.html$/, "/").replace(/\/+$/, "") || "/";
    if (norm === here) {
      links[i].classList.add("is-active");
      break;
    }
  }

  // Scroll-spy for the table of contents. Uses the heading anchors the docs
  // theme generates, so it only wires up when they are present.
  var headings = document.querySelectorAll(".doc h1[id], .doc h2[id], .doc h3[id]");
  if (headings.length === 0) return;

  var tocLinks = {};
  var tocAnchors = document.querySelectorAll(".toc a[href^='#']");
  for (var j = 0; j < tocAnchors.length; j++) {
    tocLinks[tocAnchors[j].getAttribute("href").slice(1)] = tocAnchors[j];
  }

  var active = null;

  function setActive(id) {
    if (id === active) return;
    if (active && tocLinks[active]) tocLinks[active].classList.remove("is-active");
    active = id;
    if (tocLinks[id]) tocLinks[id].classList.add("is-active");
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