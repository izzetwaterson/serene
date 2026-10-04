/* Serene eklentisi popup penceresi.
 * Arka plan betiginden durumu ceker ve saniyede bir tazeler; boylece
 * ilerleme cubuklari canli kalir. */

"use strict";

const statusEl = document.getElementById("status");
const taskListEl = document.getElementById("task-list");
const emptyEl = document.getElementById("empty");
const candidateListEl = document.getElementById("candidate-list");
const candidatesEmptyEl = document.getElementById("candidates-empty");
const candidateCountEl = document.getElementById("candidate-count");
const downloadAllEl = document.getElementById("download-all");
const takeoverEl = document.getElementById("takeover");
const notifyEl = document.getElementById("notify");
const openAppEl = document.getElementById("open-app");
const openOptionsEl = document.getElementById("open-options");

applyI18n();

let pollTimer = null;

/** Son render edilen adaylar; "Hepsini indir" bunlari kullanir. */
let currentCandidates = [];

function formatBytes(bytes) {
  if (!bytes || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function formatSpeed(bytesPerSecond) {
  if (!bytesPerSecond || bytesPerSecond <= 0) return "";
  return `${formatBytes(bytesPerSecond)}${t("speedSuffix")}`;
}

function statusLabel(status) {
  switch (status) {
    case "downloading":
      return t("statusDownloading");
    case "queued":
      return t("statusQueued");
    case "paused":
      return t("statusPaused");
    case "completed":
      return t("statusCompleted");
    case "failed":
      return t("statusFailed");
    default:
      return status || "";
  }
}

function kindLabel(kind) {
  switch (kind) {
    case "hls":
      return "HLS";
    case "dash":
      return "DASH";
    default:
      return t("kindFile");
  }
}

/**
 * Yakalanan adaylar. URL'ler sayfadan gelir; bu yuzden metin her zaman
 * textContent ile yazilir, innerHTML'e ham URL konmaz.
 */
function renderCandidates(candidates) {
  const list = Array.isArray(candidates) ? candidates : [];
  currentCandidates = list;

  candidateListEl.textContent = "";
  candidatesEmptyEl.hidden = list.length > 0;
  candidateCountEl.textContent = list.length ? String(list.length) : "";
  downloadAllEl.disabled = list.length === 0;

  for (const candidate of list) {
    const item = document.createElement("li");
    item.className = "task";

    const head = document.createElement("div");
    head.className = "candidate__head";

    const badge = document.createElement("span");
    badge.className = `kind kind--${candidate.kind || "file"}`;
    badge.textContent = kindLabel(candidate.kind);

    const name = document.createElement("span");
    name.className = "candidate__name";
    name.textContent = candidate.filename || candidate.url;
    name.title = candidate.url;

    const button = document.createElement("button");
    button.type = "button";
    button.className = "mini";
    button.textContent = t("downloadButton");
    button.addEventListener("click", () => downloadCandidates([candidate.url]));

    head.append(badge, name, button);

    const meta = document.createElement("div");
    meta.className = "candidate__meta";
    meta.textContent = [
      candidate.size > 0 ? formatBytes(candidate.size) : t("sizeUnknown"),
      candidate.site,
    ]
      .filter(Boolean)
      .join(" · ");

    item.append(head, meta);
    candidateListEl.append(item);
  }
}

function renderTasks(tasks) {
  const visible = (tasks || []).filter(
    (task) => task.status !== "completed" || Date.now() / 1000 - (task.finishedAt || 0) < 30
  );

  taskListEl.textContent = "";
  emptyEl.hidden = visible.length > 0;

  for (const task of visible.slice(0, 6)) {
    const ratio = task.total > 0 ? Math.min(task.downloaded / task.total, 1) : 0;

    const item = document.createElement("li");
    item.className = "task";

    const head = document.createElement("div");
    head.className = "task__head";

    const name = document.createElement("span");
    name.className = "task__name";
    name.textContent = task.filename || task.url;
    name.title = task.url;

    const meta = document.createElement("span");
    meta.className = "task__meta";
    meta.textContent =
      task.status === "downloading"
        ? `${formatSpeed(task.speed)} · ${Math.round(ratio * 100)}%`
        : `${statusLabel(task.status)} · ${formatBytes(task.total)}`;

    head.append(name, meta);

    const bar = document.createElement("div");
    bar.className = "bar";
    const fill = document.createElement("div");
    fill.className = `bar__fill bar__fill--${task.status}`;
    fill.style.width = `${Math.round(ratio * 100)}%`;
    bar.append(fill);

    item.append(head, bar);
    taskListEl.append(item);
  }
}

async function refresh() {
  let state;
  try {
    state = await browser.runtime.sendMessage({ type: "popup:state" });
  } catch {
    state = null;
  }

  if (!state) {
    statusEl.textContent = t("popupStatusNoBackground");
    statusEl.className = "status status--bad";
    return;
  }

  if (state.connected) {
    statusEl.textContent = t("popupStatusConnected");
    statusEl.className = "status status--ok";
  } else {
    statusEl.textContent = t("popupStatusAppClosed");
    statusEl.className = "status status--bad";
  }

  takeoverEl.checked = Boolean(state.settings?.takeover);
  notifyEl.checked = state.settings?.notify !== false;
  renderCandidates(state.candidates);
  renderTasks(state.tasks);
}

async function save(patch) {
  await browser.runtime.sendMessage({ type: "popup:save-settings", settings: patch });
  await refresh();
}

/** Secilen adaylari Serene'ye verir. */
async function downloadCandidates(urls) {
  if (!urls.length) return;
  downloadAllEl.disabled = true;
  await browser.runtime.sendMessage({ type: "popup:download-candidates", urls });
  await refresh();
}

takeoverEl.addEventListener("change", () => save({ takeover: takeoverEl.checked }));
notifyEl.addEventListener("change", () => save({ notify: notifyEl.checked }));

downloadAllEl.addEventListener("click", () => {
  downloadCandidates(currentCandidates.map((candidate) => candidate.url));
});

openAppEl.addEventListener("click", async () => {
  openAppEl.disabled = true;
  openAppEl.textContent = t("popupOpenAppBusy");
  const result = await browser.runtime.sendMessage({ type: "popup:open-app" });
  openAppEl.disabled = false;
  openAppEl.textContent = t("popupOpenApp");
  if (!result?.ok) {
    statusEl.textContent = t("popupStatusOpenFailed");
    statusEl.className = "status status--bad";
  }
  await refresh();
});

openOptionsEl.addEventListener("click", () => browser.runtime.openOptionsPage());

refresh();
pollTimer = setInterval(refresh, 1000);

window.addEventListener("unload", () => {
  if (pollTimer) clearInterval(pollTimer);
});
