/* Serene — arayüz katmanı. Rust tarafındaki komutlara ve olaylara bağlanır. */

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const { getCurrentWindow } = window.__TAURI__.window;

const state = {
  tasks: [],
  filter: "all",
  category: null,
  query: "",
  settings: null,
  disk: null,
  /* Tarayicidan yakalanan medya onerileri (eklenti koprusu). */
  captures: [],
  /* "tasks" | "captures" — orta alanda hangi kok gorunum cizilecek. */
  view: "tasks",
  /* Kopru durumu; null ise eklenti bagli degil sayilir. */
  bridge: null,
  /* Yalnızca sonraki indirmeler için geçerli klasör; null ise genel ayar kullanılır. */
  destOverride: null,
};

let toastTimer = null;
let confirmResolve = null;
/* Acilistaki mevcut kayitlar bildirim gostermesin diye ilk liste buraya alinir. */
let knownCaptureIds = new Set();
/* Onay bekleyen devralmalar; pencere bunlari sirayla gosterir. */
let handoffQueue = [];
/* Pencerede su an duran gorevin id'si; null ise pencere kapali. */
let handoffId = null;

/* ---------- biçimlendirme yardımcıları ---------- */

const UNITS = ["B", "KB", "MB", "GB", "TB"];

function fmtBytes(bytes) {
  if (!bytes || bytes <= 0) return "0 B";
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < UNITS.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = unit === 0 || value >= 100 ? 0 : 1;
  return `${value.toFixed(digits)} ${UNITS[unit]}`;
}

function fmtSpeed(bytesPerSecond) {
  if (!bytesPerSecond || bytesPerSecond <= 0) return "—";
  return `${fmtBytes(bytesPerSecond)}/s`;
}

function fmtEta(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  if (seconds < 60) return `${Math.round(seconds)} sn`;
  if (seconds < 3600) {
    return `${Math.floor(seconds / 60)} dk ${Math.round(seconds % 60)} sn`;
  }
  return `${Math.floor(seconds / 3600)} sa ${Math.floor((seconds % 3600) / 60)} dk`;
}

const MONTHS = ["Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"];

function fmtWhen(unixSeconds) {
  if (!unixSeconds) return "";
  const then = new Date(unixSeconds * 1000);
  const now = new Date();
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const startOfThen = new Date(then.getFullYear(), then.getMonth(), then.getDate());
  const dayDiff = Math.round((startOfToday - startOfThen) / 86400000);
  const clock = `${String(then.getHours()).padStart(2, "0")}:${String(then.getMinutes()).padStart(2, "0")}`;

  if (dayDiff === 0) return `Bugün, ${clock}`;
  if (dayDiff === 1) return `Dün, ${clock}`;
  return `${then.getDate()} ${MONTHS[then.getMonth()]}, ${clock}`;
}

function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[ch]));
}

function percentOf(task) {
  if (task.status === "completed") return 100;
  if (!task.total) return 0;
  return Math.min(100, Math.max(0, (task.downloaded / task.total) * 100));
}

/* ---------- kategori görünümü ---------- */

const CATEGORY_STYLE = {
  video: { icon: "movie", box: "bg-primary-fixed/40", tone: "text-primary" },
  audio: { icon: "music_note", box: "bg-primary-fixed/40", tone: "text-primary" },
  image: { icon: "image", box: "bg-tertiary-fixed/40", tone: "text-tertiary" },
  document: { icon: "description", box: "bg-surface-container-high", tone: "text-primary" },
  software: { icon: "code", box: "bg-primary-fixed/40", tone: "text-primary" },
  archive: { icon: "folder_zip", box: "bg-tertiary-fixed/40", tone: "text-tertiary" },
  other: { icon: "draft", box: "bg-surface-container-high", tone: "text-secondary" },
};

function styleOf(task) {
  return CATEGORY_STYLE[task.category] || CATEGORY_STYLE.other;
}

/* ---------- görev durumu yardımcıları ---------- */

const IN_PROGRESS = new Set(["downloading", "paused"]);

function countBy(filter) {
  switch (filter) {
    case "active":
      return state.tasks.filter((t) => IN_PROGRESS.has(t.status)).length;
    case "completed":
      return state.tasks.filter((t) => t.status === "completed").length;
    case "queued":
      return state.tasks.filter((t) => t.status === "queued").length;
    case "failed":
      return state.tasks.filter((t) => t.status === "failed").length;
    default:
      return state.tasks.length;
  }
}

function metaLine(task) {
  /* Onay bekleyen gorev duraklatilmis dogar; satirda neden bekledigi yazsin. */
  if (task.pending) {
    return `${task.total ? fmtBytes(task.total) : "Boyut bilinmiyor"} • Onay bekliyor`;
  }
  if (task.status === "completed") {
    return `${fmtBytes(task.total)} • ${fmtWhen(task.finished_at)}`;
  }
  if (task.status === "failed") {
    return task.error || "Bilinmeyen hata";
  }
  if (task.status === "queued") {
    const size = task.total ? `${fmtBytes(task.total)} • ` : "";
    return `${size}Kuyrukta bekliyor`;
  }
  if (task.status === "paused") {
    return `${fmtBytes(task.downloaded)} / ${fmtBytes(task.total)} • Duraklatıldı`;
  }

  const parts = [`${fmtBytes(task.downloaded)} / ${fmtBytes(task.total)}`, fmtSpeed(task.speed)];
  if (task.total && task.speed > 0) {
    const eta = fmtEta((task.total - task.downloaded) / task.speed);
    if (eta) parts.push(`Kalan süre: ${eta}`);
  } else if (!task.total) {
    parts.push("Boyut bilinmiyor");
  }
  return parts.join(" • ");
}

function barTone(task) {
  if (task.status === "failed") return "bg-error/70";
  if (task.status === "paused") return "bg-primary/45";
  if (task.status === "completed") return "bg-primary/60";
  return "bg-primary";
}

/* ---------- kart üretimi ---------- */

function iconButton(task, action, icon, title, tone) {
  return `<button data-action="${action}" data-id="${task.id}" title="${title}"
    class="w-9 h-9 rounded-full ${tone} flex items-center justify-center transition-colors cursor-pointer">
    <span class="material-symbols-outlined text-[18px]">${icon}</span>
  </button>`;
}

const TONE_NEUTRAL = "bg-surface-container hover:bg-surface-container-high text-secondary";
const TONE_DANGER = "bg-error-container/50 hover:bg-error-container text-on-error-container";
const TONE_PRIMARY = "bg-primary/10 hover:bg-primary/20 text-primary";

function actionsFor(task) {
  switch (task.status) {
    case "downloading":
      return (
        iconButton(task, "pause", "pause", "Duraklat", TONE_NEUTRAL) +
        iconButton(task, "remove", "close", "İptal Et", TONE_DANGER)
      );
    case "paused":
      return (
        (task.pending ? iconButton(task, "info", "info", "Bilgileri Aç", TONE_PRIMARY) : "") +
        iconButton(task, "resume", "play_arrow", "Devam Et", TONE_PRIMARY) +
        iconButton(task, "remove", "close", "İptal Et", TONE_DANGER)
      );
    case "queued":
      return iconButton(task, "remove", "close", "Kuyruktan Çıkar", TONE_DANGER);
    case "failed":
      return (
        iconButton(task, "retry", "refresh", "Yeniden Dene", TONE_PRIMARY) +
        iconButton(task, "remove", "close", "Kaldır", TONE_DANGER)
      );
    case "completed":
      return (
        iconButton(task, "open", "open_in_new", "Dosyayı Aç", TONE_NEUTRAL) +
        iconButton(task, "reveal", "folder_open", "Klasörde Göster", TONE_NEUTRAL) +
        iconButton(task, "remove", "delete", "Kaldır", TONE_DANGER)
      );
    default:
      return "";
  }
}

function statusChip(task) {
  if (task.pending) {
    return '<span class="text-[10px] font-semibold px-2 py-0.5 rounded-full bg-tertiary-fixed/50 text-on-tertiary-container flex-shrink-0">Onay bekliyor</span>';
  }
  const map = {
    downloading: ["Devam ediyor", "bg-primary-fixed/50 text-on-primary-fixed"],
    paused: ["Duraklatıldı", "bg-surface-container text-secondary"],
    queued: ["Kuyrukta", "bg-tertiary-fixed/50 text-on-tertiary-container"],
    failed: ["Hata", "bg-error-container/70 text-on-error-container"],
    completed: ["Tamamlandı", "bg-primary-fixed/50 text-on-primary-fixed"],
  };
  const [label, tone] = map[task.status] || map.queued;
  return `<span class="text-[10px] font-semibold px-2 py-0.5 rounded-full ${tone} flex-shrink-0">${label}</span>`;
}

function activeCard(task) {
  const style = styleOf(task);
  return `
  <div data-task-id="${task.id}" class="bg-surface-container-lowest rounded-3xl p-6 shadow-soft flex flex-col gap-4 transition-all hover:shadow-float">
    <div class="flex items-start justify-between gap-4">
      <div class="flex items-center gap-3.5 min-w-0">
        <div class="w-12 h-12 rounded-2xl ${style.box} flex items-center justify-center ${style.tone} flex-shrink-0">
          <span class="material-symbols-outlined text-[24px]">${style.icon}</span>
        </div>
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <h3 class="font-body font-semibold text-base text-on-surface truncate" title="${esc(task.filename)}">${esc(task.filename)}</h3>
            ${statusChip(task)}
          </div>
          <p class="text-xs text-secondary font-mono mt-0.5 truncate" title="${esc(metaLine(task))}" data-meta>${esc(metaLine(task))}</p>
        </div>
      </div>
      <div class="flex items-center gap-1.5 flex-shrink-0">${actionsFor(task)}</div>
    </div>
    <div class="w-full h-2 rounded-full bg-surface-container overflow-hidden">
      <div class="h-full ${barTone(task)} rounded-full transition-all duration-300" style="width: ${percentOf(task)}%" data-bar></div>
    </div>
  </div>`;
}

function completedCard(task) {
  const style = styleOf(task);
  return `
  <div data-task-id="${task.id}" class="bg-surface-container-low rounded-3xl p-5 shadow-soft flex items-center justify-between gap-4 transition-all hover:shadow-float">
    <div class="flex items-center gap-3.5 min-w-0">
      <div class="w-10 h-10 rounded-xl ${style.box} flex items-center justify-center ${style.tone} flex-shrink-0">
        <span class="material-symbols-outlined text-[20px]">${style.icon}</span>
      </div>
      <div class="min-w-0">
        <h4 class="font-body font-medium text-sm text-on-surface truncate" title="${esc(task.filename)}">${esc(task.filename)}</h4>
        <p class="text-[11px] text-secondary font-mono truncate" data-meta>${esc(metaLine(task))}</p>
      </div>
    </div>
    <div class="flex items-center gap-1.5 flex-shrink-0">${actionsFor(task)}</div>
  </div>`;
}

function emptyState(icon, title, hint) {
  return `
  <div class="flex flex-col items-center justify-center text-center py-14 px-6 bg-surface-container-low/50 rounded-3xl border border-dashed border-outline-variant">
    <div class="w-14 h-14 rounded-full bg-surface-container flex items-center justify-center text-outline mb-4">
      <span class="material-symbols-outlined text-[26px]">${icon}</span>
    </div>
    <p class="font-headline text-lg text-on-background">${esc(title)}</p>
    <p class="text-secondary text-[13px] mt-1.5 max-w-sm leading-relaxed">${esc(hint)}</p>
  </div>`;
}

/* bulk: baslik sagina ham HTML eklemek icin (toplu indir/temizle dugmeleri). */
function sectionHeader(title, badge, action, bulk = "") {
  const pulse = title === "Aktif İndirmeler"
    ? '<span class="w-2.5 h-2.5 rounded-full bg-primary animate-pulse"></span>'
    : "";
  const badgeHtml = badge
    ? `<span class="text-xs font-mono text-secondary bg-surface-container px-2.5 py-1 rounded-full">${esc(badge)}</span>`
    : "";
  const actionHtml = action
    ? `<button data-jump="${action.filter}" class="text-xs font-semibold text-primary hover:underline cursor-pointer">${esc(action.label)}</button>`
    : "";
  /* bulk varken rozet ve dugmeler sagda tek kume olarak dursun. */
  const right = bulk
    ? `<div class="flex items-center gap-3">${badgeHtml}${bulk}${actionHtml}</div>`
    : `${badgeHtml}${actionHtml}`;
  return `
  <div class="flex items-center justify-between gap-3 px-2">
    <h2 class="font-headline text-xl text-on-background font-normal flex items-center gap-2">${pulse}${esc(title)}</h2>
    ${right}
  </div>`;
}

/* ---------- tarayici yakalamalari ---------- */

const CAPTURE_KIND_LABEL = { hls: "HLS", dash: "DASH", file: "Dosya" };

function captureKindLabel(kind) {
  return CAPTURE_KIND_LABEL[kind] || CAPTURE_KIND_LABEL.file;
}

/* Akislarda tur, duz dosyalarda icerik turu ikonu belirler. */
const CAPTURE_STREAM_STYLE = { icon: "movie", box: "bg-tertiary-fixed/40", tone: "text-tertiary" };

function captureKindStyle(kind, contentType) {
  if (kind === "hls" || kind === "dash") return CAPTURE_STREAM_STYLE;
  const type = String(contentType || "");
  if (type.startsWith("image/")) return CATEGORY_STYLE.image;
  if (type.startsWith("audio/")) return CATEGORY_STYLE.audio;
  if (type.startsWith("video/")) return CATEGORY_STYLE.video;
  if (type.includes("pdf") || type.startsWith("text/")) return CATEGORY_STYLE.document;
  return CATEGORY_STYLE.other;
}

/* Dosya adi yoksa URL'nin son yol parcasina, o da yoksa site adina duser. */
function captureName(item) {
  const given = String(item.filename || "").trim();
  if (given) return given;

  const withoutQuery = String(item.url || "").split(/[?#]/)[0];
  const last = withoutQuery.split("/").filter(Boolean).pop() || "";
  let decoded = last;
  try {
    decoded = decodeURIComponent(last);
  } catch {
    /* bozuk yuzde kodlamasi ham haliyle kalsin */
  }
  return decoded.trim() || String(item.site || "").trim() || "Medya";
}

function captureKindChip(kind) {
  const map = {
    hls: "bg-primary-fixed/50 text-on-primary-fixed",
    dash: "bg-tertiary-fixed/50 text-on-tertiary-container",
    file: "bg-surface-container text-secondary",
  };
  return `<span class="text-[10px] font-semibold px-2 py-0.5 rounded-full ${map[kind] || map.file} flex-shrink-0">${captureKindLabel(kind)}</span>`;
}

function captureButton(item, action, icon, title, tone) {
  return `<button data-capture="${action}" data-id="${esc(item.id)}" title="${title}"
    class="w-9 h-9 rounded-full ${tone} flex items-center justify-center transition-colors cursor-pointer">
    <span class="material-symbols-outlined text-[18px]">${icon}</span>
  </button>`;
}

function captureCard(item) {
  const style = captureKindStyle(item.kind, item.contentType);
  const name = captureName(item);
  const line = [
    String(item.site || "").trim(),
    item.size > 0 ? fmtBytes(item.size) : "Boyut bilinmiyor",
    fmtWhen(item.createdAt),
  ].filter(Boolean).join(" • ");

  return `
  <div data-capture-id="${esc(item.id)}" title="${esc(item.url)}" class="bg-surface-container-low rounded-3xl p-5 shadow-soft flex items-center justify-between gap-4 transition-all hover:shadow-float">
    <div class="flex items-center gap-3.5 min-w-0">
      <div class="w-10 h-10 rounded-xl ${style.box} flex items-center justify-center ${style.tone} flex-shrink-0">
        <span class="material-symbols-outlined text-[20px]">${style.icon}</span>
      </div>
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <h4 class="font-body font-medium text-sm text-on-surface truncate" title="${esc(name)}">${esc(name)}</h4>
          ${captureKindChip(item.kind)}
        </div>
        <p class="text-[11px] text-secondary font-mono truncate" title="${esc(line)}">${esc(line)}</p>
      </div>
    </div>
    <div class="flex items-center gap-1.5 flex-shrink-0">
      ${captureButton(item, "dismiss", "close", "Yoksay", TONE_NEUTRAL)}
      ${captureButton(item, "download", "download", "İndir", TONE_PRIMARY)}
    </div>
  </div>`;
}

function filteredCaptures() {
  if (!state.query) return state.captures;
  const needle = state.query.toLocaleLowerCase("tr");
  const hit = (value) => String(value || "").toLocaleLowerCase("tr").includes(needle);
  return state.captures.filter((c) => hit(c.url) || hit(c.filename) || hit(c.site));
}

function renderCaptures() {
  const root = document.getElementById("task-root");
  const list = filteredCaptures();

  const bulk = list.length
    ? '<button data-capture-all class="text-xs font-semibold text-primary hover:underline cursor-pointer">Hepsini indir</button>'
    : "";
  const clear = state.captures.length
    ? '<button data-capture-clear class="text-xs font-semibold text-secondary hover:text-on-surface transition-colors cursor-pointer">Tümünü temizle</button>'
    : "";

  root.innerHTML = `<section class="flex flex-col gap-4">
    ${sectionHeader("Tarayıcıdan Yakalananlar", `${list.length} medya`, null, bulk + clear)}
    ${
      list.length
        ? `<div class="grid grid-cols-1 gap-4">${list.map(captureCard).join("")}</div>`
        : emptyState("travel_explore", "Yakalanan medya yok", "Tarayıcıda oynatılan bir video veya ses burada belirir. Eklenti bağlıysa yakalamalar kendiliğinden düşer.")
    }
  </section>`;
}

/* ---------- listeleme ---------- */

function matchesQuery(task) {
  if (!state.query) return true;
  const needle = state.query.toLocaleLowerCase("tr");
  return (
    task.filename.toLocaleLowerCase("tr").includes(needle) ||
    task.url.toLocaleLowerCase("tr").includes(needle)
  );
}

function filteredTasks() {
  let list = state.tasks;
  if (state.category) list = list.filter((t) => t.category === state.category);
  if (state.query) list = list.filter(matchesQuery);
  return list;
}

const FILTER_TITLES = {
  all: "Tüm İndirmeler",
  active: "Devam Edenler",
  completed: "Tamamlananlar",
  queued: "Kuyrukta",
  failed: "Hata Verenler",
};

const CATEGORY_TITLES = {
  video: "Videolar",
  audio: "Sesler",
  image: "Görseller",
  document: "Belgeler",
  software: "Yazılımlar",
  archive: "Sıkıştırılmış",
  other: "Diğer",
};

function renderTaskRoot() {
  if (state.view === "captures") {
    renderCaptures();
    return;
  }

  const root = document.getElementById("task-root");
  const isDefaultView = state.filter === "all" && !state.category && !state.query;

  if (isDefaultView) {
    const inFlight = state.tasks.filter((t) => t.status !== "completed");
    const done = state.tasks.filter((t) => t.status === "completed");

    const activeSection = inFlight.length
      ? `<section class="flex flex-col gap-4">
           ${sectionHeader("Aktif İndirmeler", `${inFlight.length} görev`)}
           <div class="grid grid-cols-1 gap-4">${inFlight.map(activeCard).join("")}</div>
         </section>`
      : `<section class="flex flex-col gap-4">
           ${sectionHeader("Aktif İndirmeler")}
           ${emptyState("downloading", "Şu an inen bir şey yok", "Yukarıdaki alana bir bağlantı yapıştırın; gerisini Serene halledecek.")}
         </section>`;

    const doneSection = done.length
      ? `<section class="flex flex-col gap-4 mt-2">
           ${sectionHeader("Son Tamamlananlar", null, { label: "Tümünü Gör", filter: "completed" })}
           <div class="grid grid-cols-1 md:grid-cols-2 gap-4">${done.slice(0, 8).map(completedCard).join("")}</div>
         </section>`
      : "";

    root.innerHTML = activeSection + doneSection;
    return;
  }

  const list = filteredTasks();
  const title = state.category
    ? CATEGORY_TITLES[state.category] || "Kategori"
    : FILTER_TITLES[state.filter];

  root.innerHTML = `<section class="flex flex-col gap-4">
    ${sectionHeader(title, `${list.length} görev`)}
    ${
      list.length
        ? `<div class="grid grid-cols-1 gap-4">${list.map(activeCard).join("")}</div>`
        : emptyState("search_off", "Burada bir şey yok", "Bu görünümde eşleşen bir indirme bulunamadı.")
    }
  </section>`;
}

function renderSidebar() {
  for (const key of ["all", "active", "completed", "queued", "failed"]) {
    const node = document.querySelector(`[data-count="${key}"]`);
    if (node) node.textContent = String(countBy(key));
  }

  for (const key of ["video", "audio", "image", "document", "software", "archive", "other"]) {
    const node = document.querySelector(`[data-count-cat="${key}"]`);
    if (node) node.textContent = String(state.tasks.filter((t) => t.category === key).length);
  }

  const captureCount = document.querySelector("[data-count-captures]");
  if (captureCount) captureCount.textContent = String(state.captures.length);

  for (const node of document.querySelectorAll("#queue-nav .nav-item")) {
    node.classList.toggle(
      "is-active",
      state.view === "tasks" && !state.category && state.filter === node.dataset.filter
    );
  }
  for (const node of document.querySelectorAll("#category-nav .cat-item")) {
    node.classList.toggle(
      "is-active",
      state.view === "tasks" && state.category === node.dataset.category
    );
  }

  const browserNode = document.getElementById("browser-queue");
  if (browserNode) browserNode.classList.toggle("is-active", state.view === "captures");
}

function renderSpeedPill() {
  const pill = document.getElementById("speed-pill");
  const text = document.getElementById("speed-pill-text");
  const total = state.tasks
    .filter((t) => t.status === "downloading")
    .reduce((sum, t) => sum + (t.speed || 0), 0);

  if (total > 0) {
    pill.classList.remove("hidden");
    pill.classList.add("flex");
    text.textContent = fmtSpeed(total);
  } else {
    pill.classList.add("hidden");
    pill.classList.remove("flex");
  }
}

function renderDisk() {
  const disk = state.disk;
  if (!disk) return;

  const drive = /^([A-Za-z]:)/.exec(disk.mount);
  document.getElementById("disk-label").textContent = drive ? `${drive[1]} sürücüsü` : "Disk";

  const usedPercent = disk.total > 0 ? (disk.used / disk.total) * 100 : 0;
  document.getElementById("disk-percent").textContent = `%${Math.round(usedPercent)}`;
  document.getElementById("disk-bar").style.width = `${Math.min(100, usedPercent)}%`;
  document.getElementById("disk-detail").textContent =
    `${fmtBytes(disk.used)} kullanılıyor / ${fmtBytes(disk.total)} toplam alan`;
}

function renderDestHint() {
  if (!state.settings) return;
  document.getElementById("dest-hint-text").textContent = state.settings.downloadDir;
}

function renderDestOverride() {
  const chip = document.getElementById("dest-override");
  if (state.destOverride) {
    document.getElementById("dest-override-text").textContent = state.destOverride;
    chip.classList.remove("hidden");
    chip.classList.add("flex");
  } else {
    chip.classList.add("hidden");
    chip.classList.remove("flex");
  }
}

function renderAll() {
  renderSidebar();
  renderTaskRoot();
  renderSpeedPill();
  renderDisk();
  renderDestHint();
  renderDestOverride();
}

/* ---------- ilerleme yaması (yeniden çizim yok) ---------- */

function patchProgress(ticks) {
  for (const tick of ticks) {
    const task = state.tasks.find((t) => t.id === tick.id);
    if (!task) continue;

    task.downloaded = tick.downloaded;
    task.speed = tick.speed;
    if (tick.total) task.total = tick.total;

    const node = document.querySelector(`[data-task-id="${CSS.escape(tick.id)}"]`);
    if (!node) continue;

    const bar = node.querySelector("[data-bar]");
    if (bar) bar.style.width = `${percentOf(task)}%`;

    const meta = node.querySelector("[data-meta]");
    if (meta) {
      const line = metaLine(task);
      meta.textContent = line;
      meta.title = line;
    }
  }
  renderSpeedPill();
}

/* ---------- eylemler ---------- */

async function refreshTasks() {
  state.tasks = await invoke("list_tasks");
  renderAll();
}

async function startDownload(rawUrl) {
  const input = document.getElementById("url-input");
  const button = document.getElementById("download-btn");
  const error = document.getElementById("add-error");
  const url = (rawUrl ?? input.value).trim();

  if (!url) {
    input.focus();
    return;
  }

  button.disabled = true;
  error.classList.add("hidden");

  try {
    await invoke("add_download", { url, destDir: state.destOverride });
    input.value = "";
    await refreshTasks();
  } catch (message) {
    error.textContent = String(message);
    error.classList.remove("hidden");
  } finally {
    button.disabled = false;
  }
}

async function removeTask(id) {
  const task = state.tasks.find((t) => t.id === id);
  if (!task) return;

  /* Tamamlanan bir indirme diskte gerçek bir dosya bırakır; kullanıcıya
     dosyayı da silmek isteyip istemediğini sormadan kaldırmayız. */
  if (task.status === "completed") {
    const choice = await openConfirm({
      title: "Kayıt kaldırılsın mı?",
      text: `${task.filename} — indirilen dosya diskten de silinsin mi?`,
      icon: "delete",
      buttons: [
        { label: "Dosyayı da sil", tone: "danger", value: "file" },
        { label: "Sadece listeden çıkar", tone: "neutral", value: "keep" },
        { label: "Vazgeç", tone: "ghost", value: null },
      ],
    });
    if (!choice) return;
    await invoke("remove_download", { id, deleteFile: choice === "file" });
    return;
  }

  await invoke("remove_download", { id, deleteFile: false });
}

async function runAction(action, id) {
  try {
    switch (action) {
      case "pause":
        await invoke("pause_download", { id });
        break;
      case "resume":
        await invoke("resume_download", { id });
        break;
      case "info":
        openHandoffById(id);
        break;
      case "retry":
        await invoke("retry_download", { id });
        break;
      case "remove":
        await removeTask(id);
        break;
      case "open":
        await invoke("open_task_file", { id });
        break;
      case "reveal":
        await invoke("reveal_task_file", { id });
        break;
    }
  } catch (message) {
    showToast(String(message));
  }
}

/* ---------- yakalama eylemleri ---------- */

async function refreshCaptures() {
  state.captures = await invoke("list_captures");
  knownCaptureIds = new Set(state.captures.map((c) => c.id));
  renderAll();
}

async function downloadCapture(id) {
  const item = state.captures.find((c) => c.id === id);
  const name = item ? captureName(item) : "Medya";

  try {
    await invoke("download_capture", { id, destDir: state.destOverride || null });
    /* Oneri tuketildi; listeden hemen dusur. */
    await invoke("dismiss_capture", { id });
    await refreshCaptures();
    await refreshTasks();
    showToast(`İndirme başlatıldı: ${name}`);
  } catch (message) {
    showToast(String(message));
  }
}

async function downloadAllCaptures() {
  const list = filteredCaptures();
  if (!list.length) return;

  let started = 0;
  let failed = 0;
  for (const item of list) {
    try {
      await invoke("download_capture", { id: item.id, destDir: state.destOverride || null });
      await invoke("dismiss_capture", { id: item.id });
      started += 1;
    } catch {
      failed += 1;
    }
  }

  await refreshCaptures();
  await refreshTasks();
  showToast(
    failed
      ? `${started} indirme başlatıldı, ${failed} tanesi başlatılamadı`
      : `${started} indirme başlatıldı`
  );
}

async function dismissCapture(id) {
  try {
    await invoke("dismiss_capture", { id });
    await refreshCaptures();
  } catch (message) {
    showToast(String(message));
  }
}

async function clearCaptures() {
  try {
    const removed = await invoke("clear_captures");
    await refreshCaptures();
    showToast(removed ? `${removed} kayıt temizlendi` : "Temizlenecek kayıt yok");
  } catch (message) {
    showToast(String(message));
  }
}

/* Eklenti baglantisi 5 sn'de bir tazelenir; hata olursa gri durumda kalir. */
async function refreshBridge() {
  const pill = document.getElementById("bridge-pill");
  const dot = document.getElementById("bridge-dot");
  const text = document.getElementById("bridge-text");
  if (!pill || !dot || !text) return;

  try {
    state.bridge = await invoke("bridge_status");
  } catch {
    state.bridge = null;
  }

  const online = (state.bridge?.clients || 0) > 0;
  dot.classList.toggle("bg-outline", !online);
  dot.classList.toggle("bg-primary", online);
  text.textContent = online ? "Tarayıcı bağlı" : "Tarayıcı yok";
  pill.title = online
    ? `Tarayıcı eklentisi bağlı (port ${state.bridge.port})`
    : "Tarayıcı eklentisi bağlı değil";
}

/* ---------- bildirimler ---------- */

function showToast(message) {
  const root = document.getElementById("toast-root");
  const node = document.createElement("div");
  node.className =
    "bg-surface-container-lowest rounded-2xl shadow-float border border-outline-variant/50 px-5 py-3.5 text-[13px] text-on-surface max-w-sm";
  node.textContent = message;
  root.appendChild(node);
  setTimeout(() => node.remove(), 5000);
}

function showClipboardToast(url) {
  const root = document.getElementById("toast-root");
  root.innerHTML = "";

  const node = document.createElement("div");
  node.className =
    "bg-surface-container-lowest rounded-3xl shadow-float border border-outline-variant/50 p-5 w-[370px] flex flex-col gap-3";
  node.innerHTML = `
    <div class="flex items-start gap-3">
      <div class="w-9 h-9 rounded-2xl bg-primary-fixed/40 flex items-center justify-center text-primary flex-shrink-0">
        <span class="material-symbols-outlined text-[19px]">content_paste_go</span>
      </div>
      <div class="min-w-0 flex-1">
        <p class="text-[13px] font-semibold text-on-surface">Panodan bağlantı yakalandı</p>
        <p class="text-[11px] text-secondary font-mono truncate mt-0.5" title="${esc(url)}">${esc(url)}</p>
      </div>
    </div>
    <div class="flex items-center justify-end gap-2">
      <button data-toast="dismiss" class="px-3.5 py-2 rounded-full text-[12px] font-medium text-secondary hover:text-on-surface transition-colors cursor-pointer">Yoksay</button>
      <button data-toast="download" class="px-4 py-2 rounded-full bg-primary hover:bg-primary/90 text-on-primary text-[12px] font-medium shadow-soft transition-all cursor-pointer">İndir</button>
    </div>`;

  node.querySelector('[data-toast="dismiss"]').addEventListener("click", () => {
    clearTimeout(toastTimer);
    root.innerHTML = "";
  });

  node.querySelector('[data-toast="download"]').addEventListener("click", () => {
    clearTimeout(toastTimer);
    root.innerHTML = "";
    startDownload(url);
  });

  root.appendChild(node);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    root.innerHTML = "";
  }, 12000);
}

/* Kopruden yeni bir yakalama dustugunde panodakiyle ayni kalibi kullanir. */
function showCaptureToast(item) {
  const root = document.getElementById("toast-root");
  root.innerHTML = "";

  const name = captureName(item);
  const site = String(item.site || "").trim();

  const node = document.createElement("div");
  node.className =
    "bg-surface-container-lowest rounded-3xl shadow-float border border-outline-variant/50 p-5 w-[370px] flex flex-col gap-3";
  node.innerHTML = `
    <div class="flex items-start gap-3">
      <div class="w-9 h-9 rounded-2xl bg-primary-fixed/40 flex items-center justify-center text-primary flex-shrink-0">
        <span class="material-symbols-outlined text-[19px]">travel_explore</span>
      </div>
      <div class="min-w-0 flex-1">
        <p class="text-[13px] font-semibold text-on-surface">Tarayıcıdan medya yakalandı</p>
        <p class="text-[11px] text-secondary font-mono truncate mt-0.5" title="${esc(name)}">${esc(name)}</p>
        ${site ? `<p class="text-[11px] text-outline truncate mt-0.5">${esc(site)}</p>` : ""}
      </div>
    </div>
    <div class="flex items-center justify-end gap-2">
      <button data-capture-toast="dismiss" class="px-3.5 py-2 rounded-full text-[12px] font-medium text-secondary hover:text-on-surface transition-colors cursor-pointer">Yoksay</button>
      <button data-capture-toast="download" class="px-4 py-2 rounded-full bg-primary hover:bg-primary/90 text-on-primary text-[12px] font-medium shadow-soft transition-all cursor-pointer">İndir</button>
    </div>`;

  node.querySelector('[data-capture-toast="dismiss"]').addEventListener("click", () => {
    clearTimeout(toastTimer);
    root.innerHTML = "";
    dismissCapture(item.id);
  });

  node.querySelector('[data-capture-toast="download"]').addEventListener("click", () => {
    clearTimeout(toastTimer);
    root.innerHTML = "";
    downloadCapture(item.id);
  });

  root.appendChild(node);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    root.innerHTML = "";
  }, 12000);
}

/* ---------- onay penceresi ---------- */

const CONFIRM_TONES = {
  danger: "bg-error-container hover:bg-error-container/80 text-on-error-container",
  primary: "bg-primary hover:bg-primary/90 text-on-primary shadow-soft",
  neutral: "bg-surface-container hover:bg-surface-container-high text-on-surface",
  ghost: "bg-transparent hover:bg-surface-container text-secondary",
};

/* Verilen seçeneklerden biri seçilene kadar bekleyen basit bir onay penceresi.
   Kapatılırsa null döner. */
function openConfirm({ title, text, icon = "delete", buttons }) {
  const modal = document.getElementById("confirm-modal");
  const root = document.getElementById("confirm-buttons");

  document.getElementById("confirm-icon").textContent = icon;
  document.getElementById("confirm-title").textContent = title;
  document.getElementById("confirm-text").textContent = text || "";

  return new Promise((resolve) => {
    const finish = (value) => {
      confirmResolve = null;
      modal.classList.add("hidden");
      modal.classList.remove("flex");
      root.innerHTML = "";
      resolve(value);
    };

    confirmResolve = finish;
    root.innerHTML = "";

    for (const button of buttons) {
      const node = document.createElement("button");
      node.className =
        `w-full py-2.5 rounded-full text-[13px] font-medium transition-colors cursor-pointer ${
          CONFIRM_TONES[button.tone] || CONFIRM_TONES.neutral
        }`;
      node.textContent = button.label;
      node.addEventListener("click", () => finish(button.value));
      root.appendChild(node);
    }

    modal.classList.remove("hidden");
    modal.classList.add("flex");
  });
}

function closeConfirm(value = null) {
  if (confirmResolve) confirmResolve(value);
}

/* ---------- indirme bilgileri penceresi ---------- */

/* Tarayicidan devralinan indirmeler "pending" dogar: kullanici bilgileri
   onaylayana kadar kuyruk onlari baslatmaz (bkz. should_hold). Ayni anda
   birden fazla istek gelebilecegi icin pencere bekleyenleri sirayla gosterir. */

function dirOf(dest) {
  return String(dest || "").replace(/[\\/][^\\/]*$/, "");
}

function currentHandoff() {
  return state.tasks.find((t) => t.id === handoffId) || null;
}

function renderHandoffCount() {
  const badge = document.getElementById("handoff-count");
  const waiting = handoffQueue.length;
  if (waiting > 1) {
    badge.textContent = `${waiting - 1} sırada`;
    badge.classList.remove("hidden");
  } else {
    badge.classList.add("hidden");
  }
}

function showHandoff(task) {
  const style = styleOf(task);
  const box = document.getElementById("handoff-icon-box");

  document.getElementById("handoff-icon").textContent = style.icon;
  box.className = `w-12 h-12 rounded-2xl ${style.box} ${style.tone} flex items-center justify-center flex-shrink-0`;

  document.getElementById("handoff-name").textContent = task.filename;
  document.getElementById("handoff-cat").textContent = CATEGORY_TITLES[task.category] || "Diğer";
  document.getElementById("handoff-size").textContent = task.total
    ? `${fmtBytes(task.total)} (${task.total.toLocaleString("tr-TR")} bayt)`
    : "Boyut bilinmiyor";
  document.getElementById("handoff-url").value = task.url;
  document.getElementById("handoff-dir").value = dirOf(task.dest);
  document.getElementById("handoff-filename").value = task.filename;

  /* Kategori dosya adindan turetilir; ad degistirilirse gorev kartinda
     guncellenir ama penceredeki etiket sunucunun onerdigi adi anlatir. */
  document.getElementById("handoff-note").textContent = !task.total
    ? "Sunucu boyutu bildirmedi; boyut indirme başlarken netleşecek."
    : task.resumable
      ? "Sunucu parçalı indirmeyi destekliyor; dosya birden çok bağlantıyla daha hızlı inebilir."
      : "Sunucu parçalı indirmeyi desteklemiyor; dosya tek bağlantıyla inecek.";

  handoffId = task.id;
  renderHandoffCount();

  /* Onceki turdan kalan devre disi durumu temizle. */
  document.getElementById("handoff-start").disabled = false;

  const modal = document.getElementById("handoff-modal");
  modal.classList.remove("hidden");
  modal.classList.add("flex");
}

function hideHandoff() {
  handoffId = null;
  const modal = document.getElementById("handoff-modal");
  modal.classList.add("hidden");
  modal.classList.remove("flex");
}

/* Sirayi listedeki gercek duruma gore tazeler: gorev silinmis, baslatilmis
   ya da baska yoldan onaylanmis olabilir. */
function syncHandoff() {
  handoffQueue = handoffQueue.filter((task) => {
    const live = state.tasks.find((t) => t.id === task.id);
    return Boolean(live && live.pending);
  });

  if (handoffId && !handoffQueue.some((task) => task.id === handoffId)) hideHandoff();
  if (!handoffId && handoffQueue.length) {
    const first = handoffQueue[0];
    showHandoff(state.tasks.find((t) => t.id === first.id) || first);
  }
  renderHandoffCount();
}

function queueHandoff(task) {
  if (!task || handoffQueue.some((t) => t.id === task.id)) return;
  handoffQueue.push(task);
  syncHandoff();
}

/* Kapatma (X, Esc, arka plan) = sonra karar ver: gorev onay beklemeye devam
   eder, listedeki "Bilgileri Ac" dugmesiyle pencere geri gelir. */
function dismissHandoff() {
  if (!handoffId) return;
  handoffQueue = handoffQueue.filter((t) => t.id !== handoffId);
  hideHandoff();
  syncHandoff();
}

function openHandoffById(id) {
  if (handoffId) return;
  const task = state.tasks.find((t) => t.id === id);
  if (!task || !task.pending) return;
  if (!handoffQueue.some((t) => t.id === task.id)) handoffQueue.push(task);
  syncHandoff();
}

/* Kayit yeri ve adi uca yazilir; `set_task_dest` gorevi onaylanmis sayip
   bekleme isaretini kaldirir. `start` true ise indirme hemen baslar. */
async function decideHandoff(start) {
  const task = currentHandoff();
  if (!task) {
    hideHandoff();
    return;
  }

  const dir = document.getElementById("handoff-dir").value.trim();
  const name = document.getElementById("handoff-filename").value.trim();
  const startButton = document.getElementById("handoff-start");
  startButton.disabled = true;

  /* Pencere ve sira once kapatilir: arada dusen bir `tasks:update` siradaki
     gorevi yanlislikla one almasin. */
  handoffQueue = handoffQueue.filter((t) => t.id !== task.id);
  hideHandoff();

  try {
    await invoke("set_task_dest", { id: task.id, destDir: dir, filename: name });
    if (start) await invoke("resume_download", { id: task.id });
  } catch (message) {
    startButton.disabled = false;
    showToast(String(message));
    queueHandoff(task);
    return;
  }
  startButton.disabled = false;

  await refreshTasks();
  syncHandoff();
  showToast(start ? `İndirme başlatıldı: ${name}` : `${name} listeye alındı`);
}

async function cancelHandoff() {
  const task = currentHandoff();
  if (!task) {
    hideHandoff();
    return;
  }

  handoffQueue = handoffQueue.filter((t) => t.id !== task.id);
  hideHandoff();

  try {
    await invoke("remove_download", { id: task.id, deleteFile: false });
  } catch (message) {
    showToast(String(message));
    queueHandoff(task);
    return;
  }

  await refreshTasks();
  syncHandoff();
  showToast("İndirme iptal edildi");
}

/* ---------- ayarlar ---------- */

function openSettings() {
  if (!state.settings) return;
  document.getElementById("set-dir").value = state.settings.downloadDir;
  document.getElementById("set-concurrent").value = state.settings.maxConcurrent;
  document.getElementById("set-connections").value = state.settings.connections;
  document.getElementById("set-clipboard").checked = state.settings.watchClipboard;
  document.getElementById("set-tray").checked = state.settings.closeToTray;
  document.getElementById("set-confirm").checked = state.settings.confirmBrowserDownload;
  document.getElementById("settings-status").textContent = "";

  const modal = document.getElementById("settings-modal");
  modal.classList.remove("hidden");
  modal.classList.add("flex");
}

function closeSettings() {
  const modal = document.getElementById("settings-modal");
  modal.classList.add("hidden");
  modal.classList.remove("flex");
}

async function saveSettings() {
  const status = document.getElementById("settings-status");
  const payload = {
    downloadDir: document.getElementById("set-dir").value.trim(),
    maxConcurrent: Number(document.getElementById("set-concurrent").value) || 3,
    connections: Number(document.getElementById("set-connections").value) || 8,
    watchClipboard: document.getElementById("set-clipboard").checked,
    closeToTray: document.getElementById("set-tray").checked,
    confirmBrowserDownload: document.getElementById("set-confirm").checked,
  };

  try {
    state.settings = await invoke("update_settings", { settings: payload });
    status.textContent = "Kaydedildi";
    status.className = "text-[12px] text-primary";
    renderDestHint();
    await refreshDisk();
    setTimeout(closeSettings, 600);
  } catch (message) {
    status.textContent = String(message);
    status.className = "text-[12px] text-on-error-container";
  }
}

async function refreshDisk() {
  try {
    state.disk = await invoke("get_disk_usage");
    renderDisk();
  } catch {
    /* disk bilgisi alınamazsa widget boş kalır */
  }
}

/* ---------- bağlantı sürükle-bırak ---------- */

/* Pencere yapılandırmasında `dragDropEnabled: false` olduğu için sürükleme
   olayları webview'e ulaşır. Tarayıcıdan sürüklenen bağlantı `text/uri-list`
   olarak gelir; dosya sürüklemeleri yok sayılır ama varsayılan gezinmeyi
   engellemek için yine de `preventDefault` çağrılır. */
function bindDropTarget() {
  const overlay = document.getElementById("drop-overlay");
  const input = document.getElementById("url-input");
  let depth = 0;

  const hasLink = (event) =>
    Array.from(event.dataTransfer?.types || []).some(
      (type) => type === "text/uri-list" || type === "text/plain"
    );

  const showOverlay = (visible) => {
    overlay.classList.toggle("hidden", !visible);
    overlay.classList.toggle("flex", visible);
  };

  document.addEventListener("dragenter", (event) => {
    if (!hasLink(event)) return;
    event.preventDefault();
    depth += 1;
    showOverlay(true);
  });

  document.addEventListener("dragover", (event) => {
    event.preventDefault();
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = hasLink(event) ? "copy" : "none";
    }
  });

  document.addEventListener("dragleave", () => {
    depth = Math.max(0, depth - 1);
    if (depth === 0) showOverlay(false);
  });

  document.addEventListener("drop", (event) => {
    event.preventDefault();
    depth = 0;
    showOverlay(false);

    const raw =
      event.dataTransfer?.getData("text/uri-list") ||
      event.dataTransfer?.getData("text/plain") ||
      "";
    const url = raw
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line && !line.startsWith("#"));
    if (!url) return;

    input.value = url;
    startDownload(url);
  });
}

/* ---------- olay bağlama ---------- */

/* İşletim sistemi çerçevesi kapalı olduğu için pencereyi üst bardaki
   düğmeler yönetir. Sürükleme, HTML tarafındaki data-tauri-drag-region
   özniteliğiyle Tauri'nin kendisi tarafından yapılır. */
function bindWindowControls() {
  const appWindow = getCurrentWindow();
  const maxButton = document.getElementById("win-max");
  const maxIcon = document.getElementById("win-max-icon");

  const syncMaxButton = async () => {
    try {
      const maximized = await appWindow.isMaximized();
      maxIcon.textContent = maximized ? "filter_none" : "crop_square";
      maxButton.title = maximized ? "Geri yükle" : "Büyüt";
    } catch {
      /* pencere durumu okunamazsa varsayılan simge kalır */
    }
  };

  document.getElementById("win-min").addEventListener("click", () => appWindow.minimize());
  document.getElementById("win-close").addEventListener("click", () => appWindow.close());
  maxButton.addEventListener("click", async () => {
    await appWindow.toggleMaximize();
    await syncMaxButton();
  });

  window.addEventListener("resize", syncMaxButton);
  syncMaxButton();
}

function bindUi() {
  bindWindowControls();
  bindDropTarget();

  document.getElementById("download-btn").addEventListener("click", () => startDownload());

  const input = document.getElementById("url-input");
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") startDownload();
  });
  input.addEventListener("input", () => {
    document.getElementById("add-error").classList.add("hidden");
  });

  document.getElementById("new-download").addEventListener("click", () => {
    document.getElementById("hero").scrollIntoView({ behavior: "smooth", block: "start" });
    input.focus();
  });

  document.getElementById("dest-hint").addEventListener("click", openSettings);

  document.getElementById("pick-dest").addEventListener("click", async () => {
    const picked = await invoke("pick_directory");
    if (!picked) return;
    state.destOverride = picked;
    renderDestOverride();
    showToast(`Bu indirme şuraya kaydedilecek: ${picked}`);
  });

  document.getElementById("dest-override-clear").addEventListener("click", () => {
    state.destOverride = null;
    renderDestOverride();
  });

  document.getElementById("queue-nav").addEventListener("click", (event) => {
    const button = event.target.closest("[data-filter]");
    if (!button) return;
    state.filter = button.dataset.filter;
    state.category = null;
    state.view = "tasks";
    renderAll();
  });

  document.getElementById("category-nav").addEventListener("click", (event) => {
    const button = event.target.closest("[data-category]");
    if (!button) return;
    const next = button.dataset.category;
    state.category = state.category === next ? null : next;
    state.filter = "all";
    state.view = "tasks";
    renderAll();
  });

  document.getElementById("browser-nav").addEventListener("click", (event) => {
    if (!event.target.closest("#browser-queue")) return;
    state.view = "captures";
    state.category = null;
    renderAll();
  });

  document.getElementById("task-root").addEventListener("click", (event) => {
    const jump = event.target.closest("[data-jump]");
    if (jump) {
      state.filter = jump.dataset.jump;
      state.category = null;
      renderAll();
      return;
    }
    if (event.target.closest("[data-capture-all]")) {
      downloadAllCaptures();
      return;
    }
    if (event.target.closest("[data-capture-clear]")) {
      clearCaptures();
      return;
    }
    const capture = event.target.closest("[data-capture][data-id]");
    if (capture) {
      if (capture.dataset.capture === "download") downloadCapture(capture.dataset.id);
      else dismissCapture(capture.dataset.id);
      return;
    }
    const button = event.target.closest("[data-action]");
    if (button) runAction(button.dataset.action, button.dataset.id);
  });

  const search = document.getElementById("search");
  search.addEventListener("input", () => {
    state.query = search.value.trim();
    renderAll();
  });

  document.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      search.focus();
      search.select();
    }
    if (event.key === "Escape") {
      if (handoffId) dismissHandoff();
      closeConfirm(null);
      closeSettings();
      if (document.activeElement === search) {
        search.value = "";
        state.query = "";
        search.blur();
        renderAll();
      }
      if (state.view === "captures") {
        state.view = "tasks";
        renderAll();
      }
    }
  });

  document.getElementById("open-settings").addEventListener("click", openSettings);
  document.getElementById("close-settings").addEventListener("click", closeSettings);
  document.getElementById("settings-modal").addEventListener("click", (event) => {
    if (event.target.id === "settings-modal") closeSettings();
  });
  document.getElementById("confirm-modal").addEventListener("click", (event) => {
    if (event.target.id === "confirm-modal") closeConfirm(null);
  });

  document.getElementById("browse-dir").addEventListener("click", async () => {
    const picked = await invoke("pick_directory");
    if (picked) document.getElementById("set-dir").value = picked;
  });

  document.getElementById("close-handoff").addEventListener("click", dismissHandoff);
  document.getElementById("handoff-later").addEventListener("click", () => decideHandoff(false));
  document.getElementById("handoff-start").addEventListener("click", () => decideHandoff(true));
  document.getElementById("handoff-cancel").addEventListener("click", cancelHandoff);
  document.getElementById("handoff-modal").addEventListener("click", (event) => {
    if (event.target.id === "handoff-modal") dismissHandoff();
  });
  document.getElementById("handoff-browse").addEventListener("click", async () => {
    const picked = await invoke("pick_directory");
    if (picked) document.getElementById("handoff-dir").value = picked;
  });
  document.getElementById("handoff-filename").addEventListener("keydown", (event) => {
    if (event.key === "Enter") decideHandoff(true);
  });

  document.getElementById("save-settings").addEventListener("click", saveSettings);

  document.getElementById("clear-completed").addEventListener("click", async () => {
    const removed = await invoke("clear_completed");
    await refreshTasks();
    const status = document.getElementById("settings-status");
    status.textContent = removed ? `${removed} kayıt silindi` : "Silinecek kayıt yok";
    status.className = "text-[12px] text-secondary";
  });
}

async function bindEvents() {
  await listen("tasks:update", (event) => {
    state.tasks = event.payload;
    renderAll();
    syncHandoff();
  });

  await listen("tasks:progress", (event) => {
    patchProgress(event.payload);
  });

  await listen("captures:update", (event) => {
    state.captures = event.payload || [];
    /* Yalnizca bu oturumda ilk kez gorulen kayitlar bildirim gosterir. */
    const fresh = state.captures.filter((c) => !knownCaptureIds.has(c.id));
    knownCaptureIds = new Set(state.captures.map((c) => c.id));
    renderAll();
    if (fresh.length) showCaptureToast(fresh[0]);
  });

  await listen("clipboard:link", (event) => {
    showClipboardToast(event.payload);
  });

  /* Tarayicidan devralinan indirme onay bekliyor; pencere hemen acilir.
     Olay listeden once dusse bile kart gorunsun diye liste tazelenir. */
  await listen("handoff:pending", async (event) => {
    const task = event.payload;
    if (!task || !state.tasks.some((t) => t.id === task.id)) await refreshTasks();
    queueHandoff(task);
  });

  /* Tepsi menusundeki "Ayarlar" secildiginde pencere one gelir ve bu olay duser. */
  await listen("ui:settings", () => {
    openSettings();
  });
}

async function init() {
  state.settings = await invoke("get_settings");
  state.tasks = await invoke("list_tasks");
  state.captures = await invoke("list_captures");
  /* Acilistaki kayitlar "yeni" sayilmasin. */
  knownCaptureIds = new Set(state.captures.map((c) => c.id));

  bindUi();
  await bindEvents();
  refreshBridge();
  await refreshDisk();

  /* Onceki oturumdan onay bekleyen bir devralma kalmis olabilir. */
  for (const task of state.tasks.filter((t) => t.pending)) queueHandoff(task);

  renderAll();
  document.getElementById("url-input").focus();

  setInterval(refreshDisk, 30000);
  setInterval(refreshBridge, 5000);
}

init().catch((error) => {
  document.getElementById("task-root").innerHTML = emptyState(
    "error",
    "Arayüz başlatılamadı",
    String(error)
  );
});
