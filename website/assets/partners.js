// Partner enquiry: posts the form to /api/partners as JSON.
// Without script the form still posts (the API accepts form encoding too).
(function () {
  var form = document.querySelector("[data-partners]");
  if (!form) return;
  var button = form.querySelector("button[type=submit]");
  var msg = form.querySelector(".fc-msg");
  var say = function (text, kind) { msg.textContent = text; msg.dataset.kind = kind || ""; };
  var val = function (name) { var el = form.elements[name]; return el ? String(el.value || "").trim() : ""; };
  var flag = function (name, bad) {
    var el = form.elements[name];
    if (el && el.setAttribute) el.setAttribute("aria-invalid", bad ? "true" : "false");
    return bad;
  };
  var topic = function () { var el = form.querySelector("input[name=topic]:checked"); return el ? el.value : ""; };

  // Links like "Ask about sponsoring" preselect a topic.
  document.querySelectorAll("[data-topic]").forEach(function (a) {
    a.addEventListener("click", function () {
      var el = form.querySelector("input[name=topic][value='" + a.dataset.topic + "']");
      if (el) el.checked = true;
    });
  });

  form.addEventListener("submit", function (e) {
    e.preventDefault();
    var data = {
      name: val("name"), email: val("email"), org: val("org"), site: val("site"),
      topic: topic(), message: val("message"), timing: val("timing"),
      website: form.querySelector(".hp").value
    };
    var missing = [];
    ["name", "org", "message"].forEach(function (k) { if (flag(k, !data[k])) missing.push(k); });
    if (flag("email", !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(data.email))) missing.unshift("email");
    if (missing.length) {
      say(missing[0] === "email" ? "That email doesn't look right." : "Please fill in the highlighted boxes.", "error");
      var first = form.elements[missing[0]];
      if (first && first.focus) first.focus();
      return;
    }
    button.disabled = true;
    say("Sending…");
    fetch(form.action, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) })
      .then(function (r) { return r.json().catch(function () { return {}; }).then(function (d) { return { ok: r.ok, data: d }; }); })
      .then(function (res) {
        if (res.ok && res.data.ok) {
          Array.prototype.forEach.call(form.elements, function (el) { el.disabled = true; });
          say("Thank you, your enquiry is in. We'll reply within five working days.", "ok");
        } else {
          button.disabled = false;
          var err = res.data && res.data.error;
          say(err === "email" ? "That email doesn't look right."
            : err === "fields" ? "Please fill in the required boxes."
            : "Something went wrong on our side. Please try again in a minute.", "error");
        }
      })
      .catch(function () { button.disabled = false; say("Couldn't reach us. Check your connection and try again.", "error"); });
  });
})();
