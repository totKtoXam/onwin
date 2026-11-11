/*
 * Настройки сайта onwin. Это единственный файл, который нужно править.
 *
 * repo   — "владелец/репозиторий" на GitHub. Если пусто, определяется сам:
 *          на адресе вида https://owner.github.io/onwin/ это "owner/onwin".
 * donate — способы поддержки. Показываются только заполненные поля;
 *          если пусто всё, вместо кнопок выводится короткая заметка.
 *          boosty, kofi — полные ссылки (https://...).
 *          crypto       — адреса кошельков; ключ — подпись на сайте.
 */
window.ONWIN_CONFIG = {
  repo: "",
  donate: {
    boosty: "https://boosty.to/totktoxam.d/donate",
    kofi: "https://ko-fi.com/totktoxam_d",
    crypto: {
      "USDT (TRC-20)": "",
      "Bitcoin": "",
      "TON": ""
    }
  }
};
