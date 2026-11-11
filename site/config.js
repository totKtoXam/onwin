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
      "USDT (сеть TON)": "UQAa9VE-zmykl0f8iFsEoANmLBwy0D824gtXuNB9r8-GR0RF",
      "USDT (сеть Ethereum, ERC-20)": "0xD8a53c26c32DD977B123261Dc70ebE5597c5e2C9",
      "Bitcoin (BTC)": "bc1qddmpxjrsam0ghq5zkmfpzy976nkw2s5z24n60m"
    }
  }
};
