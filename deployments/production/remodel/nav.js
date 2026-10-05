// Shared navigation bar. Include with: <script src="/_site/nav.js" defer></script>
// Styles live in a shadow root so host pages cannot break it and it cannot break them.
// Any failure leaves the page untouched.
;(function () {
  try {
    var links = [
      ["Home", "/", /^\/$/],
      ["Couch colours", "/couch-colors/", /^\/couch-colors(\/|$)/],
      ["Gallery", "/gallery/", /^\/gallery(\/|$)/],
      ["Assets", "/assets/", /^\/assets(\/|$)/],
    ]
    var path = location.pathname
    var host = document.createElement("div")
    host.id = "site-nav"
    host.style.cssText =
      "display:block;position:sticky;top:0;z-index:2147483647"
    var root = host.attachShadow({ mode: "open" })
    var style = document.createElement("style")
    style.textContent =
      ":host{all:initial}" +
      "nav{display:flex;flex-wrap:wrap;gap:.25rem;padding:.5rem 1rem;background:#1d1d1b;font:15px/1.4 system-ui,sans-serif}" +
      "a{color:#eeeeea;text-decoration:none;padding:.25rem .75rem;border-radius:.5rem}" +
      "a:hover,a:focus-visible{background:#3a3a36}" +
      "a[aria-current]{background:#8db4f2;color:#161614;font-weight:600}"
    var nav = document.createElement("nav")
    nav.setAttribute("aria-label", "Site")
    links.forEach(function (l) {
      var a = document.createElement("a")
      a.href = l[1]
      a.textContent = l[0]
      if (l[2].test(path)) a.setAttribute("aria-current", "page")
      nav.appendChild(a)
    })
    root.appendChild(style)
    root.appendChild(nav)
    var attach = function () {
      if (document.getElementById("site-nav")) return
      document.body.insertBefore(host, document.body.firstChild)
    }
    if (document.body) attach()
    else document.addEventListener("DOMContentLoaded", attach)
  } catch (e) {
    /* degrade silently */
  }
})()
