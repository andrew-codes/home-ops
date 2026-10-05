// Gallery browser. Plain JS, no build step.
// Albums come from /gallery/api/albums/<path>/ (Caddy browse JSON), previews from
// /gallery/img/<preset>/<base64url path>.<webp|jpg>, originals from /gallery/originals/<path>.
(function () {
  "use strict";

  var BASE = "/gallery";
  var IMAGE_RE = /\.(png|jpe?g|webp|gif|avif|tiff?)$/i;

  var $ = function (id) { return document.getElementById(id); };
  var treeEl = $("tree"), gridEl = $("grid"), foldersEl = $("folders"), crumbsEl = $("crumbs"), statusEl = $("status");
  var lb = $("lightbox"), lbImg = $("lb-img");

  // Browsers without webp get explicit .jpg URLs.
  var FORMAT = (function () {
    try {
      var c = document.createElement("canvas");
      c.width = c.height = 1;
      return c.toDataURL("image/webp").indexOf("data:image/webp") === 0 ? "webp" : "jpg";
    } catch (e) {
      return "jpg";
    }
  })();

  var cache = {};       // album path ("a/b/") -> Promise<{dirs, images}>
  var current = null;   // {path, images}
  var lbIndex = -1;
  var navSeq = 0;       // bumped per showAlbum; older async work checks it and bails
  var rootList = null; // <ul> holding the top-level album nodes

  function encodePath(p) {
    return p.split("/").map(encodeURIComponent).join("/");
  }
  // imgproxy takes the source as base64url of the URL-encoded path, which it
  // appends to its base URL (the originals route); see the Caddyfile.
  function previewUrl(preset, path) {
    var bytes = new TextEncoder().encode(encodePath(path)), bin = "";
    bytes.forEach(function (b) { bin += String.fromCharCode(b); });
    var token = btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    return BASE + "/img/" + preset + "/" + token + "." + FORMAT;
  }
  function originalUrl(path) { return BASE + "/originals/" + encodePath(path); }
  function hashFor(path) { return "#/" + encodePath(path); }
  function leaf(path) { return path.replace(/\/$/, "").split("/").pop(); }

  function loadAlbum(path) {
    if (!cache[path]) {
      cache[path] = fetch(BASE + "/api/albums/" + encodePath(path), { headers: { Accept: "application/json" } })
        .then(function (r) {
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        })
        .then(function (items) {
          var dirs = [], images = [];
          items.forEach(function (it) {
            // imgproxy parses the source as a URL and drops everything after '?', so such names cannot be previewed.
            if (it.name.charAt(0) === "." || it.name.indexOf("?") >= 0) return;
            if (it.is_dir) dirs.push(it.name.replace(/\/$/, ""));
            else if (IMAGE_RE.test(it.name)) images.push(it.name);
          });
          var cmp = function (a, b) { return a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" }); };
          return { dirs: dirs.sort(cmp), images: images.sort(cmp) };
        });
      cache[path].catch(function () { delete cache[path]; });
    }
    return cache[path];
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  var FOLDER_SVG = '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2.5h8.5A1.5 1.5 0 0 1 21 9v9.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5z" fill="currentColor"/></svg>';

  // ---- Album tree (sidebar) ----
  function buildTreeNode(parentPath, name) {
    var path = parentPath + name + "/";
    var li = el("li");
    var row = el("div", "row");
    row.dataset.path = path;
    var tog = el("button", "tog");
    tog.type = "button";
    tog.setAttribute("aria-expanded", "false");
    tog.setAttribute("aria-label", "Expand " + name);
    var a = el("a", "name", name);
    a.href = hashFor(path);
    row.appendChild(tog);
    row.appendChild(a);
    li.appendChild(row);
    var ul = null, filled = null;
    tog.addEventListener("click", function () { toggle(); });
    function toggle(force) {
      var open = force != null ? force : tog.getAttribute("aria-expanded") !== "true";
      tog.setAttribute("aria-expanded", String(open));
      if (!open) { if (ul) ul.hidden = true; return Promise.resolve(); }
      if (ul) { ul.hidden = false; return filled; }
      ul = el("ul");
      li.appendChild(ul);
      filled = fillList(ul, path);
      return filled;
    }
    li._open = function () { return toggle(true); };
    return li;
  }

  function fillList(ul, path) {
    return loadAlbum(path).then(function (a) {
      a.dirs.forEach(function (d) { ul.appendChild(buildTreeNode(path, d)); });
      if (!a.dirs.length && ul.parentNode && ul.parentNode.querySelector) {
        var tog = ul.parentNode.querySelector(":scope > .row > .tog");
        if (tog) tog.style.visibility = "hidden";
      }
    }).catch(function () {});
  }

  // Expand the tree down to `path` and highlight it.
  function syncTree(path, seq) {
    var parts = path.split("/").filter(Boolean);
    var container = rootList;
    var chain = Promise.resolve();
    parts.forEach(function (part, i) {
      chain = chain.then(function () {
        if (seq !== navSeq) return;
        var want = parts.slice(0, i + 1).join("/") + "/";
        var li = Array.prototype.find.call(container.children, function (x) {
          return x.firstChild.dataset.path === want;
        });
        if (!li) return;
        return li._open().then(function () { container = li.querySelector(":scope > ul"); });
      });
    });
    chain.then(function () {
      if (seq !== navSeq) return;
      Array.prototype.forEach.call(treeEl.querySelectorAll(".row.current"), function (r) { r.classList.remove("current"); });
      var cur = path ? Array.prototype.find.call(treeEl.querySelectorAll(".row"), function (r) { return r.dataset.path === path; }) : treeEl.querySelector(".row.root");
      if (cur) cur.classList.add("current");
    });
  }

  function initTree() {
    var ul = el("ul");
    var li = el("li");
    var row = el("div", "row root");
    row.dataset.path = "";
    var a = el("a", "name", "All captures");
    a.href = "#/";
    a.style.paddingLeft = "10px";
    row.appendChild(a);
    li.appendChild(row);
    ul.appendChild(li);
    treeEl.appendChild(ul);
    var sub = el("ul");
    sub.style.paddingLeft = "0";
    li.appendChild(sub);
    // Root's children live under the "All captures" entry.
    rootList = sub;
    return fillList(sub, "");
  }

  // ---- Grid ----
  function renderCrumbs(path) {
    crumbsEl.textContent = "";
    var parts = path.split("/").filter(Boolean);
    var root = el("a", null, "All captures");
    root.href = "#/";
    if (!parts.length) { crumbsEl.appendChild(el("b", null, "All captures")); return; }
    crumbsEl.appendChild(root);
    parts.forEach(function (p, i) {
      crumbsEl.appendChild(el("span", "sep", "/"));
      if (i === parts.length - 1) crumbsEl.appendChild(el("b", null, p));
      else {
        var a = el("a", null, p);
        a.href = hashFor(parts.slice(0, i + 1).join("/") + "/");
        crumbsEl.appendChild(a);
      }
    });
  }

  function showAlbum(path) {
    renderCrumbs(path);
    document.title = (path ? leaf(path) + " - " : "") + "Gallery";
    var seq = ++navSeq;
    syncTree(path, seq);
    if (current && current.path === path) return Promise.resolve(current);
    statusEl.textContent = "Loading...";
    current = null;
    return loadAlbum(path).then(function (a) {
      if (seq !== navSeq) return null;
      current = { path: path, images: a.images.map(function (n) { return path + n; }) };
      gridEl.textContent = "";
      foldersEl.textContent = "";
      a.dirs.forEach(function (d) {
        var link = el("a", "tile folder");
        link.href = hashFor(path + d + "/");
        link.insertAdjacentHTML("afterbegin", FOLDER_SVG);
        link.appendChild(el("span", null, d));
        foldersEl.appendChild(link);
      });
      a.images.forEach(function (n, i) {
        var b = el("button", "tile");
        b.type = "button";
        b.setAttribute("aria-label", "Open " + n);
        var img = el("img");
        img.loading = "lazy";
        img.decoding = "async";
        img.alt = "";
        img.src = previewUrl("thumb", path + n);
        b.appendChild(img);
        b.appendChild(el("span", "cap", n));
        b.addEventListener("click", function () { location.hash = hashFor(path + n); });
        gridEl.appendChild(b);
      });
      var count = a.images.length;
      statusEl.textContent = !a.dirs.length && !count ? "This album is empty."
        : count + (count === 1 ? " image" : " images") + (a.dirs.length ? ", " + a.dirs.length + (a.dirs.length === 1 ? " folder" : " folders") : "");
      return current;
    }).catch(function () {
      if (seq !== navSeq) return null;
      gridEl.textContent = "";
      foldersEl.textContent = "";
      current = null;
      statusEl.textContent = "Could not load this album.";
    });
  }

  // ---- Lightbox ----
  function openImage(path) {
    var i = current ? current.images.indexOf(path) : -1;
    if (i < 0) { closeLightbox(true); return; }
    lbIndex = i;
    lb.hidden = false;
    document.body.style.overflow = "hidden";
    lb.classList.add("loading");
    lbImg.onload = lbImg.onerror = function () { lb.classList.remove("loading"); };
    lbImg.src = previewUrl("preview", path);
    lbImg.alt = leaf(path);
    $("lb-name").textContent = leaf(path);
    var dl = $("lb-download");
    dl.href = originalUrl(path) + "?download=1";
    dl.setAttribute("download", leaf(path));
    $("lb-count").textContent = (i + 1) + " / " + current.images.length;
    $("lb-prev").style.visibility = i > 0 ? "visible" : "hidden";
    $("lb-next").style.visibility = i < current.images.length - 1 ? "visible" : "hidden";
    $("lb-close").focus();
    // Warm the neighbours.
    [i - 1, i + 1].forEach(function (j) {
      if (current.images[j]) new Image().src = previewUrl("preview", current.images[j]);
    });
  }

  function closeLightbox(skipHash) {
    lb.hidden = true;
    lbImg.removeAttribute("src");
    document.body.style.overflow = "";
    if (!skipHash && current) location.hash = hashFor(current.path);
  }

  function step(d) {
    var j = lbIndex + d;
    if (current && current.images[j]) location.hash = hashFor(current.images[j]);
  }

  $("lb-close").addEventListener("click", function () { closeLightbox(); });
  $("lb-prev").addEventListener("click", function () { step(-1); });
  $("lb-next").addEventListener("click", function () { step(1); });
  lb.addEventListener("click", function (e) {
    if (e.target === lb || e.target.classList.contains("lb-stage")) closeLightbox();
  });
  document.addEventListener("keydown", function (e) {
    if (lb.hidden) return;
    if (e.key === "Escape") closeLightbox();
    else if (e.key === "ArrowLeft") step(-1);
    else if (e.key === "ArrowRight") step(1);
  });
  var touchX = null;
  lb.addEventListener("touchstart", function (e) { touchX = e.touches[0].clientX; }, { passive: true });
  lb.addEventListener("touchend", function (e) {
    if (touchX == null) return;
    var dx = e.changedTouches[0].clientX - touchX;
    touchX = null;
    if (Math.abs(dx) > 50) step(dx < 0 ? 1 : -1);
  }, { passive: true });

  // ---- Routing: #/album/path/ for an album, #/album/path/file.png for an image ----
  function route() {
    var raw = location.hash.replace(/^#\/?/, "");
    var path;
    try { path = raw.split("/").map(decodeURIComponent).join("/"); } catch (e) { path = ""; }
    var isImage = path && path.slice(-1) !== "/";
    var album = isImage ? path.slice(0, path.lastIndexOf("/") + 1) : path;
    var seq = navSeq + 1;
    showAlbum(album).then(function () {
      if (seq !== navSeq) return;
      if (isImage) openImage(path);
      else if (!lb.hidden) closeLightbox(true);
    });
    document.body.classList.remove("menu-open");
    $("menu").setAttribute("aria-expanded", "false");
  }

  $("menu").addEventListener("click", function () {
    var open = document.body.classList.toggle("menu-open");
    this.setAttribute("aria-expanded", String(open));
  });

  window.addEventListener("hashchange", route);
  initTree().then(route);
})();
