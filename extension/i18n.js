/* Serene eklentisi arayuz dili.
 *
 * Arayuz tarayicinin dilini izler: mesajlar `_locales` kataloglarindan gelir,
 * varsayilan katalog `en` (manifest'teki `default_locale`). Sayfalar acilirken
 * `applyI18n()` cagirir; arka plan betigi dogrudan `t()` kullanir.
 * Anahtarlarin kataloglarla eslesmesi `scripts/check_extension.mjs` denetler.
 */

"use strict";

function t(key, substitutions) {
  return browser.i18n.getMessage(key, substitutions);
}

/**
 * `data-i18n` / `data-i18n-html` isaretli ogeleri katalogdan doldurur ve
 * belgenin dilini tarayicidan gelen dile esitler.
 */
function applyI18n(root = document) {
  for (const el of root.querySelectorAll("[data-i18n]")) {
    const text = t(el.dataset.i18n);
    if (text) el.textContent = text;
  }
  for (const el of root.querySelectorAll("[data-i18n-html]")) {
    const html = t(el.dataset.i18nHtml);
    if (html) el.innerHTML = html;
  }
  const ui = browser.i18n.getUILanguage?.() || "";
  if (ui) document.documentElement.lang = ui.split("-")[0];
}
