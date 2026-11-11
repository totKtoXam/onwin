/* onwin — общий скрипт сайта. Без внешних зависимостей. */
(function () {
  "use strict";

  var cfg = window.ONWIN_CONFIG || {};
  var PLACEHOLDER_REPO = "OWNER/onwin";
  var isWeb = location.protocol === "http:" || location.protocol === "https:";

  /* ---------- Репозиторий и адрес сайта ---------- */

  // "владелец/репозиторий": из config.js, иначе из адреса GitHub Pages
  // (owner.github.io/repo/ → owner/repo), иначе заглушка.
  function detectRepo() {
    var override = typeof cfg.repo === "string" ? cfg.repo.trim() : "";
    if (/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(override)) return override;

    var host = (location.hostname || "").toLowerCase();
    if (isWeb && /\.github\.io$/.test(host)) {
      var owner = host.split(".")[0];
      var first = location.pathname.split("/").filter(Boolean)[0] || "";
      try { first = decodeURIComponent(first); } catch (e) { /* оставить как есть */ }
      // Сайт пользователя (owner.github.io/) живёт в репозитории owner.github.io.
      if (!first || /\.[a-z0-9]+$/i.test(first)) first = host;
      return owner + "/" + first;
    }
    return PLACEHOLDER_REPO;
  }

  var repo = detectRepo();
  var repoParts = repo.split("/");
  var githubURL = "https://github.com/" + repo;

  // Адрес каталога текущей страницы, всегда с "/" на конце.
  function detectSiteBase() {
    if (isWeb) return location.origin + location.pathname.replace(/[^/]*$/, "");
    var name = repoParts[1];
    if (/\.github\.io$/i.test(name)) return "https://" + name.toLowerCase() + "/";
    return "https://" + repoParts[0].toLowerCase() + ".github.io/" + name + "/";
  }

  var siteBase = detectSiteBase();
  var installURL = siteBase + "install.sh";
  var commands = {
    install: "curl -fsSL " + installURL + " | bash",
    uninstall: "curl -fsSL " + installURL + " | bash -s -- --uninstall",
    purge: "curl -fsSL " + installURL + " | bash -s -- --uninstall --purge"
  };

  window.ONWIN = { repo: repo, githubURL: githubURL, siteBase: siteBase, commands: commands };

  var ghPaths = {
    repo: "",
    releases: "/releases",
    latest: "/releases/latest",
    issues: "/issues"
  };

  function each(selector, fn) {
    Array.prototype.forEach.call(document.querySelectorAll(selector), fn);
  }

  function fillLinks() {
    each("[data-gh]", function (a) {
      var key = a.getAttribute("data-gh");
      if (key in ghPaths) a.href = githubURL + ghPaths[key];
    });
    each("[data-cmd]", function (el) {
      var key = el.getAttribute("data-cmd");
      if (commands[key]) el.textContent = commands[key];
    });
    each("[data-repo-name]", function (el) { el.textContent = repo; });
    each("[data-install-url]", function (el) {
      el.textContent = installURL;
      if (el.tagName === "A") el.href = installURL;
    });
  }

  /* ---------- Копирование ---------- */

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
    }
    return legacyCopy(text);
  }

  function legacyCopy(text) {
    return new Promise(function (resolve, reject) {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.top = "-1000px";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      if (ok) resolve(); else reject(new Error("copy failed"));
    });
  }

  var liveRegion = null;
  function announce(message) {
    if (!liveRegion) {
      liveRegion = document.createElement("div");
      liveRegion.className = "copied-status";
      liveRegion.setAttribute("role", "status");
      liveRegion.setAttribute("aria-live", "polite");
      document.body.appendChild(liveRegion);
    }
    liveRegion.textContent = "";
    setTimeout(function () { liveRegion.textContent = message; }, 30);
  }

  function textForButton(btn) {
    if (btn.hasAttribute("data-copy")) return btn.getAttribute("data-copy");
    var sel = btn.getAttribute("data-copy-from");
    var src = sel ? document.querySelector(sel) : null;
    return src ? src.textContent.trim() : "";
  }

  function onCopyClick(event) {
    var btn = event.target.closest("[data-copy], [data-copy-from]");
    if (!btn) return;
    var text = textForButton(btn);
    if (!text) return;
    var label = btn.querySelector(".label") || btn;
    if (!btn.hasAttribute("data-label")) btn.setAttribute("data-label", label.textContent);
    copyText(text).then(function () {
      label.textContent = "Скопировано";
      announce("Скопировано в буфер обмена");
    }, function () {
      label.textContent = "Выделите и скопируйте вручную";
      var sel = btn.getAttribute("data-copy-from");
      var src = sel && document.querySelector(sel);
      if (src && window.getSelection) {
        var range = document.createRange();
        range.selectNodeContents(src);
        var s = window.getSelection();
        s.removeAllRanges();
        s.addRange(range);
      }
    }).then(function () {
      clearTimeout(btn._copyTimer);
      btn._copyTimer = setTimeout(function () { label.textContent = btn.getAttribute("data-label"); }, 2200);
    });
  }

  /* ---------- Последний выпуск (DMG) ---------- */

  function formatSize(bytes) {
    if (!bytes) return "";
    var nf = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 1 });
    if (bytes >= 1e9) return nf.format(bytes / 1073741824) + " ГБ";
    return nf.format(Math.max(1, Math.round(bytes / 1048576))) + " МБ";
  }

  function formatDate(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    return d.toLocaleDateString("ru-RU", { day: "numeric", month: "long", year: "numeric" });
  }

  function dmgOf(release) {
    if (!release || release.draft || release.prerelease || !Array.isArray(release.assets)) return null;
    for (var i = 0; i < release.assets.length; i++) {
      var a = release.assets[i];
      if (a && typeof a.name === "string" && /\.dmg$/i.test(a.name) && a.browser_download_url) return a;
    }
    return null;
  }

  function getJSON(url) {
    return fetch(url, { headers: { Accept: "application/vnd.github+json" } }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    });
  }

  function findLatestDmg() {
    var api = "https://api.github.com/repos/" + repo;
    return getJSON(api + "/releases/latest").then(function (rel) {
      var asset = dmgOf(rel);
      if (asset) return { release: rel, asset: asset };
      // Последним может оказаться выпуск движка (engine-…) без DMG — ищем дальше.
      return getJSON(api + "/releases?per_page=30").then(function (list) {
        for (var i = 0; i < list.length; i++) {
          var a = dmgOf(list[i]);
          if (a) return { release: list[i], asset: a };
        }
        throw new Error("no dmg");
      });
    });
  }

  function setupRelease() {
    var boxes = document.querySelectorAll("[data-release]");
    if (!boxes.length) return;
    Array.prototype.forEach.call(boxes, function (box) {
      var link = box.querySelector("[data-release-link]");
      if (link) link.href = githubURL + ghPaths.latest;
    });
    if (repo === PLACEHOLDER_REPO || !isWeb || !window.fetch) return;

    findLatestDmg().then(function (found) {
      var tag = String(found.release.tag_name || found.release.name || "").replace(/^v(?=\d)/, "");
      var parts = [];
      if (tag) parts.push("Версия " + tag);
      var size = formatSize(found.asset.size);
      if (size) parts.push(size);
      var date = formatDate(found.release.published_at);
      if (date) parts.push(date);
      Array.prototype.forEach.call(boxes, function (box) {
        var link = box.querySelector("[data-release-link]");
        var meta = box.querySelector("[data-release-meta]");
        if (link) {
          link.href = found.asset.browser_download_url;
          var label = link.querySelector(".label");
          if (label) label.textContent = "Скачать " + found.asset.name;
        }
        if (meta) meta.textContent = parts.join(" · ");
      });
    }).catch(function () {
      Array.prototype.forEach.call(boxes, function (box) {
        var meta = box.querySelector("[data-release-meta]");
        if (meta) meta.textContent = "Откроется страница последнего выпуска на GitHub — файл .dmg в разделе Assets.";
      });
    });
  }

  /* ---------- Поддержка проекта ---------- */

  var ICONS = {
    heart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z"/></svg>',
    cup: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 9h12v5a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5V9z"/><path d="M16 10h1.5a2.5 2.5 0 0 1 0 5H16"/><path d="M8 3.5v2M12 3.5v2"/></svg>',
    coin: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="8"/><path d="M9.5 9.5h3.75a1.75 1.75 0 0 1 0 3.5H9.5h4.25a1.75 1.75 0 0 1 0 3.5H9.5V8"/></svg>',
    soon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>'
  };

  function safeURL(value) {
    if (typeof value !== "string") return "";
    var v = value.trim();
    return /^https:\/\/[^\s]+$/i.test(v) ? v : "";
  }

  function donationMethods() {
    var d = cfg.donate || {};
    var links = [];
    var boosty = safeURL(d.boosty);
    var kofi = safeURL(d.kofi);
    if (boosty) links.push({ name: "Boosty", url: boosty, icon: ICONS.heart });
    if (kofi) links.push({ name: "Ko-fi", url: kofi, icon: ICONS.cup });
    var wallets = [];
    var crypto = d.crypto && typeof d.crypto === "object" ? d.crypto : {};
    Object.keys(crypto).forEach(function (label) {
      var addr = typeof crypto[label] === "string" ? crypto[label].trim() : "";
      if (addr) wallets.push({ label: label, address: addr });
    });
    return { links: links, wallets: wallets };
  }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function linkButton(m, primary) {
    var a = el("a", "btn " + (primary ? "btn-primary" : "btn-secondary"));
    a.href = m.url;
    a.target = "_blank";
    a.rel = "noopener";
    a.innerHTML = m.icon;
    a.appendChild(el("span", null, m.name));
    return a;
  }

  function walletRow(w) {
    var row = el("div", "wallet");
    row.appendChild(el("span", "label", w.label));
    var code = el("code", null, w.address);
    row.appendChild(code);
    var btn = el("button", "btn btn-secondary");
    btn.type = "button";
    btn.setAttribute("data-copy", w.address);
    btn.setAttribute("aria-label", "Скопировать адрес " + w.label);
    btn.appendChild(el("span", "label", "Скопировать"));
    row.appendChild(btn);
    return row;
  }

  function emptyNote() {
    var box = el("div", "donate-empty");
    box.innerHTML = ICONS.soon;
    var p = el("p");
    p.appendChild(document.createTextNode("Способы поддержки скоро появятся здесь. А пока можно помочь по-другому: поставить звезду проекту на "));
    var a = el("a", null, "GitHub");
    a.href = githubURL;
    p.appendChild(a);
    p.appendChild(document.createTextNode(" или рассказать о нём друзьям."));
    box.appendChild(p);
    return box;
  }

  function renderDonate(container) {
    var mode = container.getAttribute("data-donate") || "compact";
    var m = donationMethods();
    container.textContent = "";
    if (!m.links.length && !m.wallets.length) {
      container.appendChild(emptyNote());
      return;
    }
    if (m.links.length) {
      var row = el("div", "donate-links");
      m.links.forEach(function (link, i) { row.appendChild(linkButton(link, i === 0)); });
      container.appendChild(row);
    }
    if (m.wallets.length) {
      if (mode === "full") {
        m.wallets.forEach(function (w) { container.appendChild(walletRow(w)); });
      } else {
        var a = el("a", "btn btn-secondary");
        a.href = "donate.html#crypto";
        a.innerHTML = ICONS.coin;
        a.appendChild(el("span", null, "Криптовалютой: " + m.wallets.map(function (w) { return w.label; }).join(", ")));
        var wrap = el("div", "donate-links");
        wrap.appendChild(a);
        container.appendChild(wrap);
      }
    }
  }

  /* ---------- Сообщить о проблеме ---------- */

  var SUPPORT_ICONS = {
    chat: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v8a2.5 2.5 0 0 1-2.5 2.5H10l-4.5 3.5V17h0A2.5 2.5 0 0 1 4 14.5z"/><path d="M8.5 9.5h7M8.5 12.5h4.5"/></svg>',
    form: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="4" width="14" height="17" rx="2.5"/><path d="M9 4.5V3.5h6v1M8.5 10h7M8.5 13.5h7M8.5 17h4"/></svg>',
    mail: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5.5" width="18" height="13" rx="2.5"/><path d="M4 7.5l8 5.5 8-5.5"/></svg>'
  };

  var SUPPORT_CHECKLIST = [
    "версию onwin и macOS",
    "модель Mac (например, MacBook Air M2)",
    "какая программа или игра",
    "что вы делали и что увидели",
    "скриншот, если есть"
  ];

  // Только адрес вида name@domain; «mailto:» в начале допускается.
  function safeMailto(value) {
    if (typeof value !== "string") return "";
    var v = value.trim().replace(/^mailto:/i, "");
    return /^[^\s@?&#/:"<>]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(v) ? "mailto:" + v : "";
  }

  function supportChannels() {
    var s = cfg.support || {};
    var list = [];
    var telegram = safeURL(s.telegram);
    var form = safeURL(s.form);
    var email = safeMailto(s.email);
    if (telegram) list.push({ name: "Написать в Telegram", url: telegram, icon: SUPPORT_ICONS.chat, external: true });
    if (form) list.push({ name: "Заполнить форму", url: form, icon: SUPPORT_ICONS.form, external: true });
    if (email) list.push({ name: "Написать на почту", url: email, icon: SUPPORT_ICONS.mail, external: false });
    return list;
  }

  function renderSupport(container) {
    var mode = container.getAttribute("data-support") || "compact";
    var channels = supportChannels();
    container.textContent = "";
    container.classList.add("support-block");

    if (!channels.length) {
      var box = el("div", "donate-empty");
      box.innerHTML = ICONS.soon;
      var p = el("p", null, "Способ связи скоро появится здесь.");
      if (mode !== "full") {
        p.appendChild(document.createTextNode(" А пока загляните в советы: "));
        var tips = el("a", null, "«Если что-то не работает»");
        tips.href = "docs.html#troubleshooting";
        p.appendChild(tips);
        p.appendChild(document.createTextNode("."));
      }
      box.appendChild(p);
      container.appendChild(box);
    } else {
      var row = el("div", "support-links");
      channels.forEach(function (c, i) {
        var a = el("a", "btn btn-lg " + (i === 0 ? "btn-primary" : "btn-secondary"));
        a.href = c.url;
        if (c.external) { a.target = "_blank"; a.rel = "noopener"; }
        a.innerHTML = c.icon;
        a.appendChild(el("span", null, c.name));
        row.appendChild(a);
      });
      container.appendChild(row);
      // QR code of the Telegram link: a phone camera opens the group straight away (desktop only, see CSS).
      var qr = (cfg.support || {}).telegramQR;
      if (mode === "full" && qr && /^img\/[\w.-]+\.svg$/.test(qr) && channels[0].name === "Написать в Telegram") {
        var fig = el("figure", "support-qr");
        var img = el("img");
        img.src = qr; img.width = 160; img.height = 160; img.alt = "QR-код группы поддержки onwin в Telegram";
        img.onerror = function () { fig.hidden = true; };
        fig.appendChild(img);
        fig.appendChild(el("figcaption", null, "Или наведите камеру телефона"));
        container.appendChild(fig);
      }
    }

    if (mode === "full") {
      var check = el("div", "note note-plain");
      check.appendChild(el("p", "support-check-title", "Чтобы мы быстрее помогли, напишите:"));
      var ul = el("ul", "list support-check");
      SUPPORT_CHECKLIST.forEach(function (item) { ul.appendChild(el("li", null, item)); });
      check.appendChild(ul);
      container.appendChild(check);
    } else {
      container.appendChild(el("p", "muted small support-check",
        "Напишите: " + SUPPORT_CHECKLIST.join(", ") + "."));
    }

    var dev = el("p", "support-dev");
    var gh = el("a", null, "Для разработчиков: GitHub Issues");
    gh.href = githubURL + ghPaths.issues;
    dev.appendChild(gh);
    container.appendChild(dev);
  }


  /* ---------- Страница «Обновления» ---------- */

  function setupReleasesPage() {
    var box = document.querySelector("[data-releases]");
    if (!box) return;
    function fail(text) {
      box.textContent = "";
      var p = el("p", "release-empty", text + " ");
      var a = el("a", null, "Открыть выпуски на GitHub");
      a.href = githubURL + ghPaths.releases;
      p.appendChild(a);
      box.appendChild(p);
    }
    if (repo === PLACEHOLDER_REPO || !isWeb || !window.fetch) { fail("Список доступен на опубликованном сайте."); return; }
    // body_html: release notes already rendered and sanitized by GitHub.
    fetch("https://api.github.com/repos/" + repo + "/releases?per_page=100",
          { headers: { "Accept": "application/vnd.github.html+json" } })
      .then(function (r) { if (!r.ok) throw new Error(String(r.status)); return r.json(); })
      .then(function (list) {
        var apps = list.filter(function (r) { return !r.draft && /^v\d/.test(r.tag_name || ""); });
        box.textContent = "";
        if (!apps.length) { fail("Выпусков пока нет."); return; }
        var latestShown = false;
        apps.forEach(function (rel, i) {
          var version = rel.tag_name.replace(/^v/, "");
          var card = el("article", "card release");
          var head = el("div", "release-head");
          head.appendChild(el("h2", null, "onwin " + version));
          if (!latestShown && !rel.prerelease) { head.appendChild(el("span", "badge", "последняя")); latestShown = true; }
          else if (rel.prerelease) head.appendChild(el("span", "badge", "тестовая"));
          var date = formatDate(rel.published_at);
          if (date) head.appendChild(el("span", "release-date", date));
          card.appendChild(head);

          var actions = el("div", "release-actions");
          (rel.assets || []).forEach(function (asset) {
            var kind = /\.dmg$/i.test(asset.name) ? "Скачать DMG" : /-app\.zip$/i.test(asset.name) ? "Приложение без движка (zip)" : "";
            if (!kind) return;
            var a = el("a", "btn " + (kind === "Скачать DMG" ? "btn-primary" : "btn-secondary"));
            a.href = asset.browser_download_url;
            a.appendChild(el("span", null, kind + (formatSize(asset.size) ? " · " + formatSize(asset.size) : "")));
            actions.appendChild(a);
          });
          var page = el("a", "btn btn-secondary", "Страница выпуска");
          page.href = rel.html_url;
          actions.appendChild(page);
          card.appendChild(actions);

          var cmdId = "cmd-v" + i;
          var cmd = el("div", "command small-cmd");
          var code = el("code", null, "curl -fsSL " + installURL + " | bash -s -- --version " + version);
          code.id = cmdId;
          cmd.appendChild(code);
          var btn = el("button", "btn btn-primary");
          btn.type = "button";
          btn.setAttribute("data-copy-from", "#" + cmdId);
          btn.appendChild(el("span", "label", "Скопировать"));
          cmd.appendChild(btn);
          card.appendChild(el("p", "muted small", "Установить именно эту версию через Терминал:"));
          card.appendChild(cmd);

          if (rel.body_html) {
            var details = el("details", "release-notes");
            if (i === 0) details.open = true;
            details.appendChild(el("summary", null, "Что нового и как установить"));
            var body = el("div");
            body.innerHTML = rel.body_html;
            details.appendChild(body);
            card.appendChild(details);
          }
          box.appendChild(card);
        });
      })
      .catch(function () { fail("Не удалось загрузить список выпусков."); });
  }

  /* ---------- Запуск ---------- */

  function init() {
    fillLinks();
    each("[data-donate]", renderDonate);
    each("[data-support]", renderSupport);
    setupRelease();
    setupReleasesPage();
    document.addEventListener("click", onCopyClick);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
