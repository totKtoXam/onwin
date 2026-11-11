/* onwin — общий скрипт сайта. Без внешних зависимостей. */
(function () {
  "use strict";

  var cfg = window.ONWIN_CONFIG || {};
  var PLACEHOLDER_REPO = "OWNER/onwin";
  var isWeb = location.protocol === "http:" || location.protocol === "https:";

  /* ---------- Языки ---------- */

  // Russian lives at the site root, translations in en/, zh/, kk/ (same file names).
  // The page language comes from <html lang>; every text this script writes is taken from I18N.
  var LANGS = [
    { code: "ru", tag: "ru", dir: "", locale: "ru-RU" },
    { code: "en", tag: "en", dir: "en/", locale: "en-US" },
    { code: "zh", tag: "zh-Hans", dir: "zh/", locale: "zh-CN" },
    { code: "kk", tag: "kk", dir: "kk/", locale: "kk-KZ" }
  ];

  var I18N = {
    ru: {
      copy: "Скопировать", copied: "Скопировано", copiedLive: "Скопировано в буфер обмена",
      copyManual: "Выделите и скопируйте вручную",
      copyAddress: function (w) { return "Скопировать адрес " + w; },
      gb: " ГБ", mb: " МБ",
      versionMeta: function (tag, beta) { return (beta ? "Бета-версия " : "Версия ") + tag; },
      download: function (tag, beta) { return "Скачать onwin " + tag + (beta ? " (бета)" : ""); },
      releaseFallback: "Откроется страница последнего выпуска на GitHub — файл .dmg в разделе Assets.",
      network: null,
      crypto: "Криптовалюта",
      donateSoon: ["Способы поддержки скоро появятся здесь. А пока можно помочь по-другому: поставить звезду проекту на ", " или рассказать о нём друзьям."],
      telegram: "Написать в Telegram", telegramSub: "", form: "Заполнить форму", mail: "Написать на почту",
      issuesSub: "для разработчиков",
      checklist: ["версию onwin и macOS", "модель Mac (например, MacBook Air M2)", "какая программа или игра",
        "что вы делали и что увидели", "скриншот, если есть"],
      listJoin: ", ", listEnd: ".",
      supportSoon: "Способ связи скоро появится здесь.",
      tips: [" А пока загляните в советы: ", "«Если что-то не работает»", "."],
      qrAlt: "QR-код группы поддержки onwin в Telegram", qrCaption: "Или наведите камеру телефона",
      checkTitle: "Чтобы мы быстрее помогли, напишите:", checkShort: "Напишите: ",
      releasesOpen: "Открыть выпуски на GitHub", releasesOffline: "Список доступен на опубликованном сайте.",
      releasesNone: "Выпусков пока нет.", releasesFail: "Не удалось загрузить список выпусков.",
      badgeLatest: "последняя", badgePre: "тестовая", badgeBeta: "бета",
      dmg: "Скачать DMG", zip: "Приложение без движка (zip)", releasePage: "Страница выпуска",
      thisVersion: "Установить именно эту версию через Терминал:", notes: "Что нового и как установить",
      downloads: function (n, s) { return "Скачано " + s + " " + ({ one: "раз", few: "раза", many: "раз" }[plural(n)] || "раза"); }
    },
    en: {
      copy: "Copy", copied: "Copied", copiedLive: "Copied to clipboard",
      copyManual: "Select and copy it manually",
      copyAddress: function (w) { return "Copy " + w + " address"; },
      gb: " GB", mb: " MB",
      versionMeta: function (tag, beta) { return (beta ? "Beta " : "Version ") + tag; },
      download: function (tag, beta) { return "Download onwin " + tag + (beta ? " (beta)" : ""); },
      releaseFallback: "Opens the latest release on GitHub — the .dmg file is under Assets.",
      network: function (n) { return n + " network"; },
      crypto: "Crypto",
      donateSoon: ["Donation options will appear here soon. Meanwhile, you can help in other ways: star the project on ", " or tell your friends about it."],
      telegram: "Telegram chat", telegramSub: "in Russian", form: "Fill in a form", mail: "Send an email",
      issuesSub: "in English",
      checklist: ["your onwin and macOS versions", "your Mac model (for example, MacBook Air M2)", "which program or game",
        "what you did and what you saw", "a screenshot, if you have one"],
      listJoin: ", ", listEnd: ".",
      supportSoon: "Contact options will appear here soon.",
      tips: [" Meanwhile, see the tips in ", "“If something doesn’t work”", "."],
      qrAlt: "QR code of the onwin support group in Telegram", qrCaption: "Or point your phone’s camera here",
      checkTitle: "To help us help you faster, tell us:", checkShort: "Please tell us: ",
      releasesOpen: "Open releases on GitHub", releasesOffline: "The list is available on the published site.",
      releasesNone: "No releases yet.", releasesFail: "Couldn’t load the list of releases.",
      badgeLatest: "latest", badgePre: "pre-release", badgeBeta: "beta",
      dmg: "Download DMG", zip: "App without the engine (zip)", releasePage: "Release page",
      thisVersion: "Install exactly this version with Terminal:", notes: "What’s new and how to install (in Russian)",
      downloads: function (n, s) { return "Downloaded " + s + (plural(n) === "one" ? " time" : " times"); },
      bar: "This site is also available in English.", barGo: "Switch to English", barClose: "Close"
    },
    zh: {
      copy: "复制", copied: "已复制", copiedLive: "已复制到剪贴板",
      copyManual: "请手动选中并复制",
      copyAddress: function (w) { return "复制 " + w + " 地址"; },
      gb: " GB", mb: " MB",
      versionMeta: function (tag, beta) { return (beta ? "测试版 " : "版本 ") + tag; },
      download: function (tag, beta) { return "下载 onwin " + tag + (beta ? "（测试版）" : ""); },
      releaseFallback: "将打开 GitHub 上最新版本的发布页面，.dmg 文件位于 Assets 部分。",
      network: function (n) { return n + " 网络"; },
      crypto: "加密货币",
      donateSoon: ["捐助方式即将在这里公布。在此之前，您也可以用其他方式支持项目：在 ", " 上为项目点亮星标，或者把它推荐给朋友。"],
      telegram: "Telegram 群组", telegramSub: "使用俄语交流", form: "填写表单", mail: "发送邮件",
      issuesSub: "可使用英语",
      checklist: ["onwin 和 macOS 的版本", "Mac 型号（例如 MacBook Air M2）", "哪个程序或游戏",
        "您做了什么、看到了什么", "截图（如果有）"],
      listJoin: "；", listEnd: "。",
      supportSoon: "联系方式即将在这里公布。",
      tips: [" 在此之前，可以先看看", "“遇到问题怎么办”", "中的建议。"],
      qrAlt: "onwin Telegram 支持群组的二维码", qrCaption: "或用手机相机扫描",
      checkTitle: "为了更快帮到您，请写明：", checkShort: "请写明：",
      releasesOpen: "在 GitHub 上查看所有版本", releasesOffline: "版本列表只在正式发布的网站上显示。",
      releasesNone: "暂无发布版本。", releasesFail: "无法加载版本列表。",
      badgeLatest: "最新", badgePre: "预发布", badgeBeta: "测试版",
      dmg: "下载 DMG", zip: "不含引擎的应用（zip）", releasePage: "发布页面",
      thisVersion: "通过“终端”安装这个版本：", notes: "更新内容与安装说明（俄语）",
      downloads: function (n, s) { return "已下载 " + s + " 次"; },
      bar: "本网站有简体中文版。", barGo: "切换到中文", barClose: "关闭"
    },
    kk: {
      copy: "Көшіру", copied: "Көшірілді", copiedLive: "Алмасу буферіне көшірілді",
      copyManual: "Белгілеп, қолмен көшіріңіз",
      copyAddress: function (w) { return w + " мекенжайын көшіру"; },
      gb: " ГБ", mb: " МБ",
      versionMeta: function (tag, beta) { return (beta ? "Бета нұсқа " : "Нұсқа ") + tag; },
      download: function (tag, beta) { return "onwin " + tag + (beta ? " (бета)" : "") + " жүктеп алу"; },
      releaseFallback: "GitHub-тағы соңғы шығарылым беті ашылады — .dmg файлы Assets бөлімінде.",
      network: function (n) { return n + " желісі"; },
      crypto: "Криптовалюта",
      donateSoon: ["Қолдау тәсілдері жақында осында пайда болады. Әзірге басқаша көмектесуге болады: ", " сайтында жобаға жұлдызша қойыңыз немесе ол туралы достарыңызға айтыңыз."],
      telegram: "Telegram-чат", telegramSub: "орыс тілінде", form: "Форманы толтыру", mail: "Поштаға жазу",
      issuesSub: "ағылшын тілінде",
      checklist: ["onwin және macOS нұсқасы", "Mac үлгісі (мысалы, MacBook Air M2)", "қандай бағдарлама немесе ойын",
        "не істедіңіз және не көрдіңіз", "скриншот, бар болса"],
      listJoin: ", ", listEnd: ".",
      supportSoon: "Байланыс тәсілі жақында осында пайда болады.",
      tips: [" Әзірге ", "«Бір нәрсе істемесе»", " бөліміндегі кеңестерді қараңыз."],
      qrAlt: "onwin Telegram қолдау тобының QR коды", qrCaption: "Немесе телефон камерасын бағыттаңыз",
      checkTitle: "Тезірек көмектесуіміз үшін мыналарды жазыңыз:", checkShort: "Жазыңыз: ",
      releasesOpen: "GitHub-та шығарылымдарды ашу", releasesOffline: "Тізім жарияланған сайтта ғана көрінеді.",
      releasesNone: "Әзірге шығарылымдар жоқ.", releasesFail: "Шығарылымдар тізімін жүктеу мүмкін болмады.",
      badgeLatest: "соңғы", badgePre: "сынақ", badgeBeta: "бета",
      dmg: "DMG жүктеп алу", zip: "Қозғалтқышсыз қолданба (zip)", releasePage: "Шығарылым беті",
      thisVersion: "Дәл осы нұсқаны Терминал арқылы орнату:", notes: "Не жаңа және қалай орнату керек (орыс тілінде)",
      downloads: function (n, s) { return s + " рет жүктелді"; },
      bar: "Бұл сайттың қазақша нұсқасы бар.", barGo: "Қазақшаға ауысу", barClose: "Жабу"
    }
  };

  function langOf(tag) {
    var t = String(tag || "").toLowerCase();
    for (var i = 0; i < LANGS.length; i++) {
      if (t === LANGS[i].tag.toLowerCase() || t.split("-")[0] === LANGS[i].code) return LANGS[i];
    }
    return LANGS[0];
  }

  var lang = langOf(document.documentElement.lang);
  var T = I18N[lang.code];

  // Plural category ("one", "few", "many", "other") for the page language.
  function plural(n) {
    try { return new Intl.PluralRules(lang.locale).select(n); } catch (e) { return n === 1 ? "one" : "other"; }
  }

  // Site root: the folder site.js is loaded from (pages in en/ load ../site.js).
  var script = document.currentScript;
  var rootBase = script && script.src ? script.src.replace(/[?#].*$/, "").replace(/[^/]*$/, "") : "";

  var LANG_KEY = "onwin-lang";
  function readLangChoice() {
    try { return localStorage.getItem(LANG_KEY) || ""; } catch (e) { return ""; }
  }
  function saveLangChoice(code) {
    try { localStorage.setItem(LANG_KEY, code); } catch (e) { /* private mode: just don't remember */ }
  }

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

  // Адрес корня сайта (папка site.js), всегда с "/" на конце: команда установки одна для всех языков.
  function detectSiteBase() {
    if (isWeb) return /^https?:/.test(rootBase) ? rootBase : location.origin + location.pathname.replace(/[^/]*$/, "");
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
    // «Напишите нам» links go straight to the support chat; without one they keep their docs href.
    each("[data-support-chat]", function (a) {
      var chat = safeURL((cfg.support || {}).telegram);
      if (chat) { a.href = chat; a.target = "_blank"; a.rel = "noopener"; }
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
      label.textContent = T.copied;
      announce(T.copiedLive);
    }, function () {
      label.textContent = T.copyManual;
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
    var nf = new Intl.NumberFormat(lang.locale, { maximumFractionDigits: 1 });
    if (bytes >= 1e9) return nf.format(bytes / 1073741824) + T.gb;
    return nf.format(Math.max(1, Math.round(bytes / 1048576))) + T.mb;
  }

  function formatDate(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    var text = d.toLocaleDateString(lang.locale, { day: "numeric", month: "long", year: "numeric" });
    // Some browsers have no Kazakh month names and print "2026 M11 11".
    if (lang.code === "kk" && /M\d/.test(text)) {
      var months = ["қаңтар", "ақпан", "наурыз", "сәуір", "мамыр", "маусым", "шілде", "тамыз", "қыркүйек", "қазан", "қараша", "желтоқсан"];
      text = d.getFullYear() + " жылғы " + d.getDate() + " " + months[d.getMonth()];
    }
    return text;
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
      var beta = /^0\./.test(tag);
      if (tag) parts.push(T.versionMeta(tag, beta) + " · DMG");
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
          if (label) label.textContent = T.download(tag, beta);
        }
        if (meta) meta.textContent = parts.join(" · ");
      });
    }).catch(function () {
      Array.prototype.forEach.call(boxes, function (box) {
        var meta = box.querySelector("[data-release-meta]");
        if (meta) meta.textContent = T.releaseFallback;
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

  // config.js labels are Russian ("USDT (сеть TON)"); translated pages get the word "network" in their language.
  function walletLabel(label) {
    if (!T.network) return label;
    return label.replace(/\(сеть ([^,)]+)/, function (m, net) { return "(" + T.network(net.trim()); });
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
      if (addr) wallets.push({ label: walletLabel(label), address: addr });
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
    btn.setAttribute("aria-label", T.copyAddress(w.label));
    btn.appendChild(el("span", "label", T.copy));
    row.appendChild(btn);
    return row;
  }

  function emptyNote() {
    var box = el("div", "donate-empty");
    box.innerHTML = ICONS.soon;
    var p = el("p");
    p.appendChild(document.createTextNode(T.donateSoon[0]));
    var a = el("a", null, "GitHub");
    a.href = githubURL;
    p.appendChild(a);
    p.appendChild(document.createTextNode(T.donateSoon[1]));
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
    var row = el("div", "donate-links");
    m.links.forEach(function (link, i) { row.appendChild(linkButton(link, i === 0)); });
    if (m.wallets.length && mode !== "full") {
      // Compact: one button the size of the others; addresses are on donate.html#crypto.
      var coins = [];
      m.wallets.forEach(function (w) {
        var c = String(w.label).split(/[\s(]/)[0].replace(/^Bitcoin$/i, "BTC");
        if (c && coins.indexOf(c) < 0) coins.push(c);
      });
      var a = el("a", "btn btn-secondary btn-sub");
      a.href = "donate.html#crypto";
      a.innerHTML = ICONS.coin;
      var label = el("span", null, T.crypto);
      label.appendChild(el("small", null, coins.join(" · ")));
      a.appendChild(label);
      row.appendChild(a);
    }
    if (row.childNodes.length) container.appendChild(row);
    if (m.wallets.length && mode === "full") {
      m.wallets.forEach(function (w) { container.appendChild(walletRow(w)); });
    }
  }

  /* ---------- Сообщить о проблеме ---------- */

  var SUPPORT_ICONS = {
    // Service marks, used only on links to that service (Telegram / GitHub brand guidelines allow this).
    telegram: '<svg class="svc-logo" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="12" fill="#2AABEE"/><path fill="#fff" d="M5.4 11.7l11.6-4.5c.54-.2 1.01.13.83.95l-1.97 9.3c-.15.66-.54.82-1.09.51l-3-2.21-1.45 1.4c-.16.16-.3.29-.6.29l.21-3.06 5.57-5.03c.24-.21-.05-.33-.38-.12l-6.88 4.33-2.96-.92c-.64-.2-.66-.64.13-.95z"/></svg>',
    github: '<svg class="svc-logo" viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>',
    chat: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v8a2.5 2.5 0 0 1-2.5 2.5H10l-4.5 3.5V17h0A2.5 2.5 0 0 1 4 14.5z"/><path d="M8.5 9.5h7M8.5 12.5h4.5"/></svg>',
    form: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="4" width="14" height="17" rx="2.5"/><path d="M9 4.5V3.5h6v1M8.5 10h7M8.5 13.5h7M8.5 17h4"/></svg>',
    mail: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5.5" width="18" height="13" rx="2.5"/><path d="M4 7.5l8 5.5 8-5.5"/></svg>'
  };

  var SUPPORT_CHECKLIST = T.checklist;

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
    // The Telegram group speaks Russian: translated pages say so under the button.
    if (telegram) list.push({ id: "telegram", name: T.telegram, sub: T.telegramSub, url: telegram, icon: SUPPORT_ICONS.telegram, external: true });
    if (form) list.push({ id: "form", name: T.form, url: form, icon: SUPPORT_ICONS.form, external: true });
    if (email) list.push({ id: "email", name: T.mail, url: email, icon: SUPPORT_ICONS.mail, external: false });
    return list;
  }

  // Same size as the chat buttons; GitHub Issues is for developers (needs an account).
  function githubIssuesButton() {
    var gh = el("a", "btn btn-lg btn-secondary support-gh");
    gh.href = githubURL + ghPaths.issues;
    gh.target = "_blank"; gh.rel = "noopener";
    gh.innerHTML = SUPPORT_ICONS.github;
    var label = el("span", null, "GitHub Issues");
    label.appendChild(el("small", null, T.issuesSub));
    gh.appendChild(label);
    return gh;
  }

  function renderSupport(container) {
    var mode = container.getAttribute("data-support") || "compact";
    var channels = supportChannels();
    container.textContent = "";
    container.classList.add("support-block");

    if (!channels.length) {
      var box = el("div", "donate-empty");
      box.innerHTML = ICONS.soon;
      var p = el("p", null, T.supportSoon);
      if (mode !== "full") {
        p.appendChild(document.createTextNode(T.tips[0]));
        var tips = el("a", null, T.tips[1]);
        tips.href = "docs.html#troubleshooting";
        p.appendChild(tips);
        p.appendChild(document.createTextNode(T.tips[2]));
      }
      box.appendChild(p);
      container.appendChild(box);
      var ghRow = el("div", "support-links");
      ghRow.appendChild(githubIssuesButton());
      container.appendChild(ghRow);
    } else {
      var row = el("div", "support-links");
      channels.forEach(function (c, i) {
        var a = el("a", "btn btn-lg " + (i === 0 ? "btn-primary" : "btn-secondary"));
        a.href = c.url;
        if (c.external) { a.target = "_blank"; a.rel = "noopener"; }
        a.innerHTML = c.icon;
        var name = el("span", null, c.name);
        if (c.sub) { a.classList.add("btn-sub"); name.appendChild(el("small", null, c.sub)); }
        a.appendChild(name);
        row.appendChild(a);
      });
      row.appendChild(githubIssuesButton());
      container.appendChild(row);
      // QR code of the Telegram link: a phone camera opens the group straight away (desktop only, see CSS).
      var qr = (cfg.support || {}).telegramQR;
      if (mode === "full" && qr && /^img\/[\w.-]+\.svg$/.test(qr) && channels[0].id === "telegram") {
        var fig = el("figure", "support-qr");
        var img = el("img");
        img.src = rootBase + qr; img.width = 160; img.height = 160; img.alt = T.qrAlt;
        img.onerror = function () { fig.hidden = true; };
        fig.appendChild(img);
        fig.appendChild(el("figcaption", null, T.qrCaption));
        container.appendChild(fig);
      }
    }

    if (mode === "full") {
      var check = el("div", "note note-plain");
      check.appendChild(el("p", "support-check-title", T.checkTitle));
      var ul = el("ul", "list support-check");
      SUPPORT_CHECKLIST.forEach(function (item) { ul.appendChild(el("li", null, item)); });
      check.appendChild(ul);
      container.appendChild(check);
    } else {
      container.appendChild(el("p", "muted small support-check",
        T.checkShort + SUPPORT_CHECKLIST.join(T.listJoin) + T.listEnd));
    }


  }


  /* ---------- Страница «Обновления» ---------- */

  function setupReleasesPage() {
    var box = document.querySelector("[data-releases]");
    if (!box) return;
    function fail(text) {
      box.textContent = "";
      var p = el("p", "release-empty", text + " ");
      var a = el("a", null, T.releasesOpen);
      a.href = githubURL + ghPaths.releases;
      p.appendChild(a);
      box.appendChild(p);
    }
    if (repo === PLACEHOLDER_REPO || !isWeb || !window.fetch) { fail(T.releasesOffline); return; }
    // body_html: release notes already rendered and sanitized by GitHub.
    fetch("https://api.github.com/repos/" + repo + "/releases?per_page=100",
          { headers: { "Accept": "application/vnd.github.html+json" } })
      .then(function (r) { if (!r.ok) throw new Error(String(r.status)); return r.json(); })
      .then(function (list) {
        saveCount(countInstalls(list));
        var apps = list.filter(function (r) { return !r.draft && /^v\d/.test(r.tag_name || ""); });
        box.textContent = "";
        if (!apps.length) { fail(T.releasesNone); return; }
        var latestShown = false;
        apps.forEach(function (rel, i) {
          var version = rel.tag_name.replace(/^v/, "");
          var card = el("article", "card release");
          var head = el("div", "release-head");
          head.appendChild(el("h2", null, "onwin " + version));
          if (!latestShown && !rel.prerelease) { head.appendChild(el("span", "badge", T.badgeLatest)); latestShown = true; }
          else if (rel.prerelease) head.appendChild(el("span", "badge", T.badgePre));
          // Every version below 1.0 is a beta.
          if (/^0\./.test(version)) head.appendChild(el("span", "badge badge-beta", T.badgeBeta));
          var date = formatDate(rel.published_at);
          if (date) head.appendChild(el("span", "release-date", date));
          card.appendChild(head);

          var actions = el("div", "release-actions");
          var downloads = 0;
          (rel.assets || []).forEach(function (asset) {
            var isDmg = /\.dmg$/i.test(asset.name);
            var kind = isDmg ? T.dmg : /-app\.zip$/i.test(asset.name) ? T.zip : "";
            if (!kind) return;
            downloads += asset.download_count || 0;
            var a = el("a", "btn " + (isDmg ? "btn-primary" : "btn-secondary"));
            a.href = asset.browser_download_url;
            a.appendChild(el("span", null, kind + (formatSize(asset.size) ? " · " + formatSize(asset.size) : "")));
            actions.appendChild(a);
          });
          if (downloads > 0) {
            head.appendChild(el("span", "release-date release-downloads", T.downloads(downloads, new Intl.NumberFormat(lang.locale).format(downloads))));
          }
          var page = el("a", "btn btn-secondary", T.releasePage);
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
          btn.appendChild(el("span", "label", T.copy));
          cmd.appendChild(btn);
          card.appendChild(el("p", "muted small", T.thisVersion));
          card.appendChild(cmd);

          if (rel.body_html) {
            var details = el("details", "release-notes");
            if (i === 0) details.open = true;
            details.appendChild(el("summary", null, T.notes));
            var body = el("div");
            body.innerHTML = rel.body_html;
            details.appendChild(body);
            card.appendChild(details);
          }
          box.appendChild(card);
        });
      })
      .catch(function () { fail(T.releasesFail); });
  }

  /* ---------- Счётчик «Нас уже» на главной ---------- */

  // Installs, not downloads: every install downloads the engine once (Terminal installer, or the light DMG on
  // first launch), or comes as a DMG with the engine inside (over 100 MB). App updates (zip, light DMG) are not counted.
  var COUNT_KEY = "onwin-installs";
  var BIG_DMG = 100 * 1024 * 1024;

  function countInstalls(list) {
    var total = 0;
    (Array.isArray(list) ? list : []).forEach(function (rel) {
      ((rel && rel.assets) || []).forEach(function (a) {
        var name = String((a && a.name) || "");
        var engine = /^onwin-engine-.+\.tar\.xz$/i.test(name) && !/sources?|src/i.test(name);  // not source archives
        if (engine || (/\.dmg$/i.test(name) && a.size > BIG_DMG)) {
          total += a.download_count || 0;
        }
      });
    });
    return total;
  }

  // The unauthenticated GitHub API allows 60 requests an hour per visitor: the last value is shared by the
  // pages of this tab for a minute.
  function readCount() {
    try {
      var c = JSON.parse(sessionStorage.getItem(COUNT_KEY) || "null");
      if (c && typeof c.n === "number" && typeof c.t === "number") return c;
    } catch (e) { /* no storage */ }
    return null;
  }
  function saveCount(n) {
    try { sessionStorage.setItem(COUNT_KEY, JSON.stringify({ n: n, t: Date.now() })); } catch (e) { /* no storage */ }
  }

  function setupCounter() {
    var box = document.querySelector("[data-counter]");
    if (!box || repo === PLACEHOLDER_REPO || !isWeb || !window.fetch || !window.requestAnimationFrame) return;
    var out = box.querySelector("[data-counter-value]");
    var sr = box.querySelector("[data-counter-sr]");
    var nf = new Intl.NumberFormat(lang.locale);
    var min = typeof cfg.counterMin === "number" && cfg.counterMin > 0 ? cfg.counterMin : 0;
    var still = !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
    var REFRESH = 120000, FRESH = 60000;
    var shown = 0, frame = 0, timer = 0, busy = false, lastTry = 0;

    function render(n) { out.textContent = nf.format(n); }

    // Counts up from zero on first appearance, then from the old value to the new one.
    function show(n) {
      if (n < min) { box.hidden = true; return; }
      var from = box.hidden ? 0 : shown;
      box.hidden = false;
      shown = n;
      if (sr) sr.textContent = nf.format(n);
      cancelAnimationFrame(frame);
      if (still || from === n) { render(n); return; }
      var start = 0;
      function step(now) {
        if (!start) start = now;
        var k = Math.min(1, (now - start) / 1200);
        render(Math.round(from + (n - from) * (1 - Math.pow(1 - k, 3))));
        if (k < 1) frame = requestAnimationFrame(step);
      }
      frame = requestAnimationFrame(step);
    }

    function schedule(ms) {
      clearTimeout(timer);
      timer = document.hidden ? 0 : setTimeout(refresh, Math.max(1000, ms));
    }

    function refresh() {
      clearTimeout(timer);
      if (document.hidden || busy) return;
      var c = readCount();
      var age = c ? Date.now() - c.t : Infinity;
      if (c && age < FRESH) { show(c.n); schedule(REFRESH - age); return; }
      busy = true;
      lastTry = Date.now();
      getJSON("https://api.github.com/repos/" + repo + "/releases?per_page=100").then(function (list) {
        var n = countInstalls(list);
        saveCount(n);
        show(n);
      }, function () {
        // Rate limit or offline: keep the number on screen; with no number at all the block stays hidden.
        if (box.hidden && c) show(c.n);
      }).then(function () { busy = false; schedule(REFRESH); });
    }

    document.addEventListener("visibilitychange", function () {
      if (document.hidden) { clearTimeout(timer); return; }
      var c = readCount();
      var age = Date.now() - Math.max(lastTry, c ? c.t : 0);
      if (age >= REFRESH) refresh(); else schedule(REFRESH - age);
    });
    refresh();
  }

  /* ---------- Счётчики посещений (по желанию, без cookie) ---------- */

  // Loaded only when filled in config.js; then the footer says the site counts visits.
  function setupAnalytics() {
    if (!isWeb) return;
    var a = cfg.analytics && typeof cfg.analytics === "object" ? cfg.analytics : {};
    var gc = typeof a.goatcounter === "string" ? a.goatcounter.trim().toLowerCase() : "";
    var cf = typeof a.cloudflareToken === "string" ? a.cloudflareToken.trim() : "";
    var on = false;
    if (/^[a-z0-9][a-z0-9-]{0,62}$/.test(gc)) {
      var g = document.createElement("script");
      g.async = true;
      g.src = "https://gc.zgo.at/count.js";
      g.setAttribute("data-goatcounter", "https://" + gc + ".goatcounter.com/count");
      document.head.appendChild(g);
      on = true;
    }
    if (/^[A-Za-z0-9]{8,64}$/.test(cf)) {
      var b = document.createElement("script");
      b.defer = true;
      b.src = "https://static.cloudflareinsights.com/beacon.min.js";
      b.setAttribute("data-cf-beacon", JSON.stringify({ token: cf }));
      document.head.appendChild(b);
      on = true;
    }
    if (on) each("[data-analytics-note]", function (n) { n.hidden = false; });
  }

  /* ---------- Выбор языка ---------- */

  // A click on РУ / EN / 中文 / ҚАЗ is remembered, so the root page stops suggesting another language.
  function onLangClick(event) {
    var a = event.target.closest && event.target.closest(".lang-switch a[hreflang]");
    if (a) saveLangChoice(langOf(a.getAttribute("hreflang")).code);
  }

  // Only on the Russian pages (site root), only until the visitor has chosen: a small bar offering
  // the same page in the browser's language. Never redirects by itself.
  function suggestLanguage() {
    if (lang.code !== "ru" || readLangChoice() || !rootBase) return;
    if (document.querySelector('meta[name="robots"][content*="noindex"]')) return;
    var prefs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || ""];
    var first = String(prefs[0] || "").toLowerCase().split("-")[0];
    if (!first || first === "ru" || first === "uk" || first === "be") return;
    var target = langOf(first).code !== "ru" ? langOf(first) : LANGS[1];  // anyone else: English
    var t = I18N[target.code];
    var page = location.pathname.split("/").pop() || "index.html";
    if (!/\.html$/.test(page)) page = "index.html";

    var bar = el("aside", "lang-bar");
    bar.setAttribute("lang", target.tag);
    bar.setAttribute("aria-label", t.barGo);
    var wrap = el("div", "wrap");
    wrap.appendChild(el("p", null, t.bar));
    var go = el("a", "lang-bar-go", t.barGo);
    go.href = rootBase + target.dir + page + location.hash;
    go.hreflang = target.tag;
    go.addEventListener("click", function () { saveLangChoice(target.code); });
    wrap.appendChild(go);
    var close = el("button", "lang-bar-close", "×");
    close.type = "button";
    close.setAttribute("aria-label", t.barClose);
    close.addEventListener("click", function () { saveLangChoice("ru"); bar.parentNode.removeChild(bar); });
    wrap.appendChild(close);
    bar.appendChild(wrap);
    var skip = document.querySelector(".skip-link");
    document.body.insertBefore(bar, skip ? skip.nextSibling : document.body.firstChild);
  }

  /* ---------- Запуск ---------- */

  function init() {
    fillLinks();
    each("[data-donate]", renderDonate);
    each("[data-support]", renderSupport);
    setupRelease();
    setupReleasesPage();
    setupCounter();
    setupAnalytics();
    document.addEventListener("click", onCopyClick);
    document.addEventListener("click", onLangClick);
    suggestLanguage();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
