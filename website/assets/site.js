/* Lumalook website: the few things that need script. Everything still
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
    document.querySelectorAll("[data-soon]").forEach(function (el) { el.hidden = true; });
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

  var still = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Hero timecode: runs at 24 frames a second while the frame is on screen
  var tc = document.querySelector("[data-timecode]");
  if (tc && !still && window.requestAnimationFrame) {
    var t0 = performance.now(), visible = true, raf = 0, last = "";
    var pad = function (n) { return (n < 10 ? "0" : "") + n; };
    var tick = function (now) {
      var f = Math.floor((now - t0) / (1000 / 24));
      var s = Math.floor(f / 24);
      var text = pad(Math.floor(s / 3600)) + ":" + pad(Math.floor(s / 60) % 60) + ":" + pad(s % 60) + ":" + pad(f % 24);
      if (text !== last) { tc.textContent = text; last = text; }
      raf = visible ? requestAnimationFrame(tick) : 0;
    };
    raf = requestAnimationFrame(tick);
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (entries) {
        visible = entries[0].isIntersecting;
        if (visible && !raf) raf = requestAnimationFrame(tick);
      }).observe(tc.closest(".frame") || tc);
    }
  }

  // Phones develop once the centre phone is half on screen and its picture has
  // loaded, so the change from black and white is seen rather than scrolled past.
  // It plays again each time the phone comes back after leaving the screen.
  document.querySelectorAll("[data-reveal]").forEach(function (stage) {
    var phone = stage.querySelector(".develop") || stage;
    var img = phone.querySelector("img");
    var play = function () { stage.classList.add("in"); };
    if (!("IntersectionObserver" in window)) { play(); return; }
    new IntersectionObserver(function (entries) {
      var e = entries[entries.length - 1];
      if (e.intersectionRatio >= 0.5) {
        if (!img || img.complete) play();
        else { img.addEventListener("load", play, { once: true }); img.addEventListener("error", play, { once: true }); }
      } else if (!e.isIntersecting) {
        stage.classList.remove("in");
      }
    }, { threshold: [0, 0.5] }).observe(phone);
  });

  // Look cards: touch and hold (or hold Space) to see the photo before the look
  document.querySelectorAll("[data-compare]").forEach(function (card) {
    var on = function () { card.classList.add("orig"); };
    var off = function () { card.classList.remove("orig"); };
    card.setAttribute("aria-describedby", "compare-hint");
    card.addEventListener("pointerdown", function (e) { if (e.pointerType !== "mouse") on(); });
    ["pointerup", "pointercancel", "pointerleave"].forEach(function (ev) { card.addEventListener(ev, off); });
    card.addEventListener("contextmenu", function (e) { e.preventDefault(); });
    card.addEventListener("keydown", function (e) {
      if (e.key === " " || e.key === "Enter") { e.preventDefault(); on(); }
    });
    card.addEventListener("keyup", off);
    card.addEventListener("blur", off);
  });

  // Waitlist: posts to /api/waitlist, which saves the address in Resend and
  // sends one confirmation email. Without script the form still posts.
  document.querySelectorAll("[data-waitlist]").forEach(function (form) {
    var input = form.querySelector("input[type=email]");
    var button = form.querySelector("button[type=submit]");
    var msg = form.querySelector(".wl-msg");
    var say = function (text, kind) {
      msg.textContent = text;
      msg.dataset.kind = kind || "";
    };
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var email = input.value.trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
        say("That email doesn't look right. Check it and try again.", "error");
        input.focus();
        return;
      }
      button.disabled = true;
      say("Adding you\u2026");
      fetch(form.action, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: email, website: form.querySelector(".hp").value })
      }).then(function (r) {
        return r.json().catch(function () { return {}; }).then(function (data) { return { ok: r.ok, data: data }; });
      }).then(function (res) {
        if (res.ok && res.data.ok) {
          form.classList.add("done");
          say(res.data.already ? "You're already on the list. We'll be in touch on launch day." : "You're on the list. Check your inbox for a short hello.", "ok");
          input.value = "";
        } else if (res.data && res.data.error === "email") {
          say("That email doesn't look right. Check it and try again.", "error");
        } else {
          say("Something went wrong on our side. Please try again in a minute.", "error");
        }
      }).catch(function () {
        say("You seem to be offline. Please try again.", "error");
      }).then(function () { button.disabled = false; });
    });
  });

  // Year in the footer
  document.querySelectorAll("[data-year]").forEach(function (el) { el.textContent = String(new Date().getFullYear()); });
})();
