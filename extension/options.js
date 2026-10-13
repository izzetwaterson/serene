/* Serene eklentisi ayar sayfasi. */

"use strict";

const DEFAULTS = {
  takeover: true,
  minSizeKb: 64,
  excludedHosts: [],
  notify: true,
};

const takeoverEl = document.getElementById("takeover");
const notifyEl = document.getElementById("notify");
const minSizeEl = document.getElementById("min-size");
const excludedEl = document.getElementById("excluded");
const saveEl = document.getElementById("save");
const resetEl = document.getElementById("reset");
const statusEl = document.getElementById("status");

applyI18n();

async function load() {
  const stored = await browser.storage.local.get("settings");
  const settings = { ...DEFAULTS, ...(stored.settings || {}) };

  takeoverEl.checked = Boolean(settings.takeover);
  notifyEl.checked = settings.notify !== false;
  minSizeEl.value = String(settings.minSizeKb);
  excludedEl.value = (settings.excludedHosts || []).join("\n");
}

function collect() {
  const minSize = Number(minSizeEl.value);
  return {
    takeover: takeoverEl.checked,
    notify: notifyEl.checked,
    minSizeKb: Number.isFinite(minSize) && minSize >= 0 ? Math.floor(minSize) : DEFAULTS.minSizeKb,
    excludedHosts: excludedEl.value
      .split("\n")
      .map((line) => line.trim().toLowerCase())
      .filter(Boolean),
  };
}

function flash(message) {
  statusEl.textContent = message;
  setTimeout(() => {
    if (statusEl.textContent === message) statusEl.textContent = "";
  }, 2200);
}

saveEl.addEventListener("click", async () => {
  const settings = collect();
  await browser.runtime.sendMessage({ type: "popup:save-settings", settings });
  flash(t("optionsSaved"));
});

resetEl.addEventListener("click", async () => {
  await browser.runtime.sendMessage({ type: "popup:save-settings", settings: { ...DEFAULTS } });
  await load();
  flash(t("optionsResetDone"));
});

load();
