/*
 * Настройки сайта onwin. Это единственный файл, который нужно править.
 *
 * repo   — "владелец/репозиторий" на GitHub. Если пусто, определяется сам:
 *          на адресе вида https://owner.github.io/onwin/ это "owner/onwin".
 * donate — способы поддержки. Показываются только заполненные поля;
 *          если пусто всё, вместо кнопок выводится короткая заметка.
 *          boosty, kofi — полные ссылки (https://...).
 *          crypto       — адреса кошельков; ключ — подпись на сайте.
 * support — куда писать о проблемах (блок «Сообщить о проблеме» на главной
 *          и в документации). Показываются только заполненные поля; если
 *          пусто всё, выводится заметка, что способ связи скоро появится.
 *          telegram — ссылка на чат или группу (https://t.me/...),
 *          form     — ссылка на веб-форму, где не нужен аккаунт GitHub (https://...),
 *          email    — адрес почты (name@example.org).
 * counterMin — счётчик «Нас уже» на главной прячется, пока установок меньше этого числа (0 — показывать всегда,
 *          когда GitHub ответил).
 * analytics — счётчики посещений без cookie. Пусто — ничего не подключается и строка о счётчике в подвале скрыта.
 *          goatcounter     — код сайта в GoatCounter, например "onwin" (→ https://onwin.goatcounter.com/count),
 *          cloudflareToken — токен Cloudflare Web Analytics (Websites → Add a site → JS snippet, поле "token").
 */
window.ONWIN_CONFIG = {
  repo: "",
  donate: {
    boosty: "https://boosty.to/totktoxam.d/donate",
    kofi: "https://ko-fi.com/totktoxam_d",
    crypto: {
      "USDT (сеть TON)": "UQAa9VE-zmykl0f8iFsEoANmLBwy0D824gtXuNB9r8-GR0RF",
      "USDT (сеть Ethereum, ERC-20)": "0xD8a53c26c32DD977B123261Dc70ebE5597c5e2C9",
      "Bitcoin (BTC)": "bc1qddmpxjrsam0ghq5zkmfpzy976nkw2s5z24n60m"
    }
  },
  support: {
    telegram: "https://t.me/+KGkGUTbpk0ZjNDEy",
    telegramQR: "img/telegram-qr.svg",   // QR-код той же ссылки (qrencode); пусто — без QR
    form: "",
    email: ""
  },
  counterMin: 0,
  analytics: {
    goatcounter: "",
    cloudflareToken: ""
  }
};
