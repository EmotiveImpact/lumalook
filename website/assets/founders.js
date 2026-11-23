// Founding Creators application: posts the form to /api/founders as JSON.
// Without script the form still posts (the API accepts form encoding too).
(function () {
  var form = document.querySelector("[data-founders]");
  if (!form) return;
  var button = form.querySelector("button[type=submit]");
  var msg = form.querySelector(".fc-msg");
  var say = function (text, kind) {
    msg.textContent = text;
    msg.dataset.kind = kind || "";
  };
  var val = function (name) {
    var el = form.elements[name];
    return el ? String(el.value || "").trim() : "";
  };
  var checked = function (name) {
    return Array.prototype.slice.call(form.querySelectorAll("input[name='" + name + "']:checked")).map(function (el) { return el.value; });
  };
  var flag = function (name, bad) {
    var el = form.elements[name];
    if (el && el.setAttribute) el.setAttribute("aria-invalid", bad ? "true" : "false");
    return bad;
  };

  form.addEventListener("submit", function (e) {
    e.preventDefault();
    var data = {
      name: val("name"),
      email: val("email"),
      location: val("location"),
      phone: val("phone"),
      links: val("links"),
      makes: checked("makes"),
      wrong: val("wrong"),
      want: val("want"),
      monk: (checked("monk")[0] || ""),
      consent_tone: form.elements.consent_tone.checked,
      adult: form.elements.adult.checked,
      website: form.querySelector(".hp").value
    };

    var missing = [];
    ["name", "location", "phone", "links", "wrong"].forEach(function (k) {
      if (flag(k, !data[k])) missing.push(k);
    });
    if (flag("email", !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(data.email))) missing.unshift("email");
    if (missing.length) {
      say(missing[0] === "email" ? "That email doesn't look right." : "Please fill in the highlighted boxes.", "error");
      var first = form.elements[missing[0]];
      if (first && first.focus) first.focus();
      return;
    }
    if (data.monk && !data.consent_tone) {
      say("Tick the box to let us use your skin tone, or clear the tone you picked.", "error");
      return;
    }
    if (!data.adult) {
      say("Please confirm you're 18 or over and have read the privacy policy.", "error");
      return;
    }

    button.disabled = true;
    say("Sending…");
    fetch(form.action, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data)
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (d) { return { ok: r.ok, data: d }; });
    }).then(function (res) {
      if (res.ok && res.data.ok) {
        form.classList.add("done");
        Array.prototype.forEach.call(form.elements, function (el) { el.disabled = true; });
        say("Thank you, your application is in. We read every one and will email you either way.", "ok");
      } else {
        button.disabled = false;
        var err = res.data && res.data.error;
        say(err === "email" ? "That email doesn't look right."
          : err === "fields" ? "Please fill in the required boxes."
          : "Something went wrong on our side. Please try again in a minute.", "error");
      }
    }).catch(function () {
      button.disabled = false;
      say("Couldn't reach us. Check your connection and try again.", "error");
    });
  });
})();
