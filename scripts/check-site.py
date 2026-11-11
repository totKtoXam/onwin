#!/usr/bin/env python3
"""Проверка сайта onwin (site/) во всех языках. Запуск: python3 scripts/check-site.py

Проверяет:
  * каждая страница есть в корне (русский) и в en/, zh/, kk/;
  * <html lang> соответствует папке;
  * внутренние ссылки и src ведут на существующие файлы, а якоря (#id) — на существующие id;
  * на каждой странице есть полный набор <link rel="alternate" hreflang> и переключатель языков,
    ведущий на ту же страницу в другом языке;
  * версии ?v= у style.css, config.js, site.js одинаковые на всех страницах;
  * набор id на странице одинаковый во всех языках (якоря из других страниц и из site.js не ломаются);
  * в en/ и zh/ не осталось русского текста (кроме подписей переключателя и явно разрешённого).
Код выхода 1, если есть ошибки.
"""
import os, re, sys
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "site")
SITE_URL = "https://totktoxam.github.io/onwin/"
PAGES = ["index.html", "install.html", "releases.html", "docs.html", "donate.html", "licenses.html"]
LANGS = {"": "ru", "en": "en", "zh": "zh-Hans", "kk": "kk"}
# Anchors that site.js builds at runtime (relative to the page's language folder).
JS_LINKS = ["donate.html#crypto", "docs.html#troubleshooting"]
# Russian that may stay on translated pages: switcher labels and the installer's final word
# (anything else must be wrapped in an element with lang="ru").
ALLOWED_CYRILLIC = {"РУ", "ҚАЗ", "Қазақша", "Русский", "«Готово»", "Готово"}

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
errors, warnings = [], []


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids, self.links, self.alternates, self.switch = set(), [], {}, []
        self.lang = None
        self.in_switch = 0
        self.skip = 0          # inside <script>/<style>
        self.ru = []           # stack of open elements: True when marked lang="ru"
        self.text = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "html":
            self.lang = a.get("lang")
        if "id" in a:
            if a["id"] in self.ids:
                errors.append("duplicate id %r" % a["id"])
            self.ids.add(a["id"])
        if tag == "link" and a.get("rel") == "alternate" and "hreflang" in a:
            self.alternates[a["hreflang"]] = a.get("href")
        for attr in ("href", "src"):
            if attr in a and a[attr] is not None:
                self.links.append(a[attr])
        if tag == "nav" and "lang-switch" in (a.get("class") or "").split():
            self.in_switch = 1
        elif self.in_switch and tag == "a":
            self.switch.append(a)
        if tag in ("script", "style"):
            self.skip += 1
        if tag not in VOID:
            self.ru.append((tag, (a.get("lang") or "").startswith("ru")))

    def handle_endtag(self, tag):
        for i in range(len(self.ru) - 1, -1, -1):
            if self.ru[i][0] == tag:
                del self.ru[i:]
                break
        if tag == "nav" and self.in_switch:
            self.in_switch = 0
        if tag in ("script", "style"):
            self.skip -= 1

    def handle_data(self, data):
        # Text marked lang="ru" on a translated page is intentional (e.g. a Russian release title).
        if not self.skip and data.strip() and not any(r for _, r in self.ru):
            self.text.append(data.strip())


def parse(path):
    p = Page()
    with open(path, encoding="utf-8") as f:
        src = f.read()
    p.feed(src)
    p.source = src
    return p


def page_url(d, page):
    return SITE_URL + (d + "/" if d else "") + ("" if page == "index.html" else page)


cache = {}


def get(path):
    if path not in cache:
        cache[path] = parse(path)
    return cache[path]


def check_link(src_file, link, where):
    parts = urlsplit(link)
    if parts.scheme or link.startswith("//") or link.startswith("data:"):
        return
    base_dir = os.path.dirname(src_file)
    if os.path.basename(src_file) == "404.html":
        base_dir = ROOT          # 404.html sets <base> to the site root
    target = os.path.normpath(os.path.join(base_dir, unquote(parts.path))) if parts.path else src_file
    if os.path.isdir(target):
        target = os.path.join(target, "index.html")
    if not os.path.exists(target):
        if "img/docs/" in parts.path:
            return               # screenshots are optional: the <figure> hides itself (onerror)
        errors.append("%s: broken link %s" % (where, link))
        return
    if parts.fragment and target.endswith(".html"):
        if parts.fragment not in get(target).ids:
            errors.append("%s: missing anchor %s" % (where, link))


versions = {}
for d, tag in LANGS.items():
    folder = os.path.join(ROOT, d)
    for page in PAGES + (["404.html"] if d == "" else []):
        path = os.path.join(folder, page)
        rel = os.path.relpath(path, ROOT)
        if not os.path.exists(path):
            errors.append("%s: missing page" % rel)
            continue
        p = get(path)
        if p.lang != tag:
            errors.append("%s: <html lang=%r>, expected %r" % (rel, p.lang, tag))
        for link in p.links:
            check_link(path, link, rel)
        for m in re.finditer(r'(style\.css|config\.js|site\.js)\?v=(\d+)', p.source):
            versions.setdefault(m.group(1), {}).setdefault(m.group(2), []).append(rel)

        if page != "404.html":
            for js in JS_LINKS:
                check_link(path, js, rel + " (site.js link)")
            want = {LANGS[x]: page_url(x, page) for x in LANGS}
            want["x-default"] = page_url("", page)
            if p.alternates != want:
                errors.append("%s: hreflang links differ from expected %s" % (rel, sorted(set(want.items()) ^ set(p.alternates.items()))))

        # Language switcher: one link per language, to the same page, current one marked.
        target_page = "index.html" if page == "404.html" else page
        got = {a.get("hreflang"): a for a in p.switch}
        if set(got) != set(LANGS.values()):
            errors.append("%s: language switcher has %s" % (rel, sorted(got)))
        for x, xtag in LANGS.items():
            a = got.get(xtag)
            if not a:
                continue
            base = ROOT if page == "404.html" else folder
            dest = os.path.normpath(os.path.join(base, a.get("href", "")))
            expect = os.path.normpath(os.path.join(ROOT, x, target_page))
            if dest != expect:
                errors.append("%s: switcher %s → %s" % (rel, xtag, a.get("href")))
            if (xtag == tag) != ("aria-current" in a) and page != "404.html":
                errors.append("%s: switcher aria-current wrong for %s" % (rel, xtag))

        if d in ("en", "zh"):
            left = [t for t in p.text if re.search(r"[А-Яа-яЁёӘәҒғҚқҢңӨөҰұҮүҺһІі]", t) and t not in ALLOWED_CYRILLIC]
            if left:
                errors.append("%s: Cyrillic text left: %s" % (rel, "; ".join(x[:60] for x in left[:5])))

for asset, vs in versions.items():
    if len(vs) > 1:
        errors.append("%s: different ?v= versions: %s" % (asset, {v: len(f) for v, f in vs.items()}))

for page in PAGES:
    ru = os.path.join(ROOT, page)
    if not os.path.exists(ru):
        continue
    ids = get(ru).ids
    for d in LANGS:
        if not d:
            continue
        path = os.path.join(ROOT, d, page)
        if os.path.exists(path) and get(path).ids != ids:
            diff = sorted(ids ^ get(path).ids)
            errors.append("%s/%s: ids differ from Russian page: %s" % (d, page, diff[:10]))

for w in warnings:
    print("warning:", w)
for e in errors:
    print("error:", e)
total = sum(1 for d in LANGS for _ in PAGES)
print("checked %d pages + 404: %d error(s)" % (total, len(errors)))
sys.exit(1 if errors else 0)
