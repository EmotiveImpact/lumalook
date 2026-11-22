/* LumaLook website: the few things that need script. Everything still
   reads correctly with script off. */
(function () {
  "use strict";

  /* Set this to the App Store URL on launch day, for example
     "https://apps.apple.com/app/id0000000000". While it is empty every
     download button says "Coming soon" and points at the closing band. */
  var APP_STORE_URL = "";

  /* The support address the app's Help & Support screen already uses.
     It is put together here so it never sits in the HTML for scrapers. */
  var SUPPORT_USER = "emotiveimpact";
  var SUPPORT_DOMAIN = "gmail.com";

  // Store buttons
  if (APP_STORE_URL) {
    document.querySelectorAll("[data-store]").forEach(function (a) {
      a.href = APP_STORE_URL;
      a.rel = "noopener";
      var label = a.querySelector("[data-store-label]");
      if (label) label.textContent = "Download on the App Store";
      else if (a.textContent.trim() === "Get the app") a.textContent = "Download";
    });
  }

  // Support address
  var email = SUPPORT_USER + "@" + SUPPORT_DOMAIN;
  document.querySelectorAll("[data-email]").forEach(function (el) {
    if (el.tagName === "A") {
      el.href = "mailto:" + email + (el.dataset.subject ? "?subject=" + encodeURIComponent(el.dataset.subject) : "");
    } else {
      el.textContent = email;
    }
  });
  document.querySelectorAll("[data-copy-email]").forEach(function (btn) {
    btn.hidden = false;
    btn.addEventListener("click", function () {
      var done = function () {
        var old = btn.textContent;
        btn.textContent = "Copied";
        setTimeout(function () { btn.textContent = old; }, 1600);
      };
      var fallback = function () {
        var code = btn.parentElement.querySelector("code");
        if (!code) return;
        var range = document.createRange();
        range.selectNodeContents(code);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(email).then(done, fallback);
      } else {
        fallback();
      }
    });
  });

  // Nav hairline once the page scrolls
  var nav = document.getElementById("nav");
  if (nav) {
    var onScroll = function () { nav.classList.toggle("scrolled", window.scrollY > 8); };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
  }

  // Pro: yearly or monthly
  var seg = document.querySelectorAll("[data-period]");
  if (seg.length) {
    var plan = document.getElementById("pro");
    var set = function (period) {
      seg.forEach(function (b) { b.setAttribute("aria-pressed", String(b.dataset.period === period)); });
      plan.querySelectorAll(".yearly-only").forEach(function (el) { el.hidden = period !== "yearly"; });
      plan.querySelectorAll(".monthly-only").forEach(function (el) { el.hidden = period !== "monthly"; });
    };
    seg.forEach(function (b) { b.addEventListener("click", function () { set(b.dataset.period); }); });
  }

  // Year in the footer
  document.querySelectorAll("[data-year]").forEach(function (el) { el.textContent = String(new Date().getFullYear()); });
})();
