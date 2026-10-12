// Renk/tipografi/olcu token'larini TEK bir tasarim sayfasina doker.
//
// Neden uretiliyor: elle yazilan bir tasarim sayfasi Flutter'in ikinci bir
// kopyasi olur ve ayrisir (`ui/DESIGN.md` 46 commit sonra tam da boyle iki
// yanlis iddia tasiyordu). Bu betik token'lari `theme.dart`'tan OKUR, bu
// yuzden sayfa token'lardan ayrisamaz; degisen sey sayfaya da yansir.
//
// Cikti iki dosya (ikisi de build/ altinda, commit edilmez):
//   build/design-sheet.html   - tarayicida acilabilir sayfa
//   build/design-sheet.png    - Figma sohbetine eklenebilecek goruntu
//
// Kullanim: node scripts/make_design_sheet.mjs

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const THEME = join(ROOT, "flutter_app", "lib", "src", "theme.dart");
const FONTS = join(ROOT, "flutter_app", "assets", "fonts");
const OUT_DIR = join(ROOT, "build");
const HTML = join(OUT_DIR, "design-sheet.html");
const PNG = join(OUT_DIR, "design-sheet.png");

const fail = (why) => {
  console.log("BASARISIZ: " + why);
  process.exit(1);
};

/// `const _light = _Palette( ... );` blogundan `ad: Color(0xRRGGBB[AA])`
/// ciftlerini kaynak sirasiyla cikarir. Golge listeleri (`shadowSoft` gibi
/// `List<BoxShadow>`) atlanir: sayfada swatch olarak gosterilemezler.
function palette(source, which) {
  const start = source.indexOf(`const ${which} = _Palette(`);
  if (start < 0) fail(`${which} paleti theme.dart'ta bulunamadi`);
  const end = source.indexOf("\n);", start);
  if (end < 0) fail(`${which} paleti kapanis parantezi bulunamadi`);
  const body = source.slice(start, end);
  const out = [];
  const re = /(\w+): Color\(0x([0-9A-Fa-f]{8})\)/g;
  let m;
  while ((m = re.exec(body)) !== null) out.push({ name: m[1], hex: m[2].toUpperCase() });
  if (out.length === 0) fail(`${which} paletinde renk yok`);
  return out;
}

function radii(source) {
  const out = [];
  const re = /static const double (radius\w+) = ([\d.]+);/g;
  let m;
  while ((m = re.exec(source)) !== null) out.push({ name: m[1], value: Number(m[2]) });
  if (out.length === 0) fail("theme.dart'ta yaricap token'i yok");
  return out;
}

const source = readFileSync(THEME, "utf8");
const light = palette(source, "_light");
const dark = palette(source, "_dark");
const shape = radii(source);

// `0xAARRGGBB`: ilk iki hane ALFA, sonraki altisi RGB. (Ilk surumde ters
// okunmustu; butun swatch'lar ayni soluk tonda cikti ve `primary` yesil
// gorunmedi. Uretilen bir sayfada boyle bir hata sessiz olur, o yuzden burada
// yazili duruyor.)
const css = (hex) => {
  const a = hex.slice(0, 2);
  const rgb = hex.slice(2, 8);
  const alpha = parseInt(a, 16) / 255;
  return {
    rgb: `#${rgb}`,
    rgba: `rgba(${parseInt(rgb.slice(0, 2), 16)},${parseInt(rgb.slice(2, 4), 16)},${parseInt(rgb.slice(4, 6), 16)},${alpha.toFixed(3)})`,
    opaque: a === "FF",
    label: a === "FF" ? `#${rgb}` : `#${rgb} @ 0x${a}`,
  };
};

const fontFace = (family, file, weight) =>
  `@font-face{font-family:"${family}";font-weight:${weight};src:url("../flutter_app/assets/fonts/${file}") format("truetype");}`;

for (const f of [
  ["Fraunces-Regular.ttf", "Fraunces"],
  ["Fraunces-Medium.ttf", "Fraunces"],
  ["NunitoSans-Regular.ttf", "Nunito Sans"],
  ["NunitoSans-SemiBold.ttf", "Nunito Sans"],
  ["NunitoSans-Bold.ttf", "Nunito Sans"],
  ["JetBrainsMono-Regular.ttf", "JetBrains Mono"],
  ["JetBrainsMono-Medium.ttf", "JetBrains Mono"],
]) {
  if (!existsSync(join(FONTS, f[0]))) fail(`yazi tipi yok: ${f[0]}`);
}

const swatchRows = (list) =>
  list
    .map(({ name, hex }) => {
      const c = css(hex);
      return `<div class="row">
        <span class="chip" style="background:${c.opaque ? c.rgb : c.rgba};${c.opaque ? "" : "border:1px dashed #999"}"></span>
        <code>${name}</code><span class="hex">${c.label}</span>
      </div>`;
    })
    .join("\n");

const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>Serene — design sheet</title>
<style>
${fontFace("Fraunces", "Fraunces-Regular.ttf", 400)}
${fontFace("Fraunces", "Fraunces-Medium.ttf", 500)}
${fontFace("Nunito Sans", "NunitoSans-Regular.ttf", 400)}
${fontFace("Nunito Sans", "NunitoSans-SemiBold.ttf", 600)}
${fontFace("Nunito Sans", "NunitoSans-Bold.ttf", 700)}
${fontFace("JetBrains Mono", "JetBrainsMono-Regular.ttf", 400)}
${fontFace("JetBrains Mono", "JetBrainsMono-Medium.ttf", 500)}
*{box-sizing:border-box;margin:0}
body{width:1400px;padding:40px 48px 56px;background:#F7F4ED;color:#2E3230;
  font-family:"Nunito Sans",system-ui,sans-serif}
h1{font-family:Fraunces;font-weight:400;font-size:34px;letter-spacing:-.4px}
.sub{color:#5F6660;font-size:14px;margin-top:6px;line-height:1.6}
.note{margin-top:10px;font-size:12.5px;color:#8A9088}
h2{font-family:Fraunces;font-weight:400;font-size:20px;margin:34px 0 12px;
  padding-bottom:8px;border-bottom:1px solid #DCD8CE}
.cols{display:flex;gap:40px}
.col{flex:1}
.col h3{font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:#5F6660;margin-bottom:10px}
.row{display:flex;align-items:center;gap:10px;padding:3px 0;font-size:12.5px}
.chip{width:26px;height:26px;border-radius:6px;flex:0 0 auto;border:1px solid rgba(0,0,0,.08)}
.row code{font-family:"JetBrains Mono";font-size:12px;flex:1}
.hex{font-family:"JetBrains Mono";font-size:11.5px;color:#8A9088}
.type{display:flex;align-items:baseline;gap:18px;padding:7px 0;border-bottom:1px dotted #E2DED5}
.type .spec{font-family:"JetBrains Mono";font-size:11.5px;color:#8A9088;width:270px;flex:0 0 auto}
.shapes{display:flex;gap:22px}
.shape{width:104px;height:104px;background:#fff;display:flex;flex-direction:column;
  align-items:center;justify-content:center;gap:4px;font-size:12px}
.shape b{font-family:"JetBrains Mono";font-size:15px;font-weight:500}
.shape span{color:#5F6660;font-size:11px}
.wins{display:flex;align-items:flex-end;gap:26px;margin-top:6px}
.win{border:1.5px solid #8A9088;border-radius:8px;background:rgba(255,255,255,.6);
  display:flex;flex-direction:column;align-items:center;justify-content:center;
  font-family:"JetBrains Mono";font-size:12px;color:#2E3230}
.win small{font-family:"Nunito Sans";color:#5F6660;font-size:11px;margin-top:3px}
</style></head>
<body>
<h1>Serene — design sheet</h1>
<div class="sub">The system the running app actually uses. Generated from
<code>flutter_app/lib/src/theme.dart</code> on ${new Date().toISOString().slice(0, 10)} — do not edit by hand,
the generator (<code>scripts/make_design_sheet.mjs</code>) overwrites it.</div>
<div class="note">Product: a calm Windows download manager. Warm paper, forest green, no pure white/grey/black, nothing fully saturated.
Two themes ship, both designed (dark is not an inversion: its green goes darker and the text on it goes dark).</div>

<h2>Colour</h2>
<div class="cols">
  <div class="col"><h3>Light</h3>${swatchRows(light)}</div>
  <div class="col"><h3>Dark</h3>${swatchRows(dark)}</div>
</div>

<h2>Type</h2>
<div class="type"><span class="spec">Fraunces 30 / -0.4 — hero question</span>
  <span style="font-family:Fraunces;font-size:30px;letter-spacing:-.4px">What would you like to download today?</span></div>
<div class="type"><span class="spec">Fraunces 20 — window title</span>
  <span style="font-family:Fraunces;font-size:20px">Download Info</span></div>
<div class="type"><span class="spec">Nunito Sans 15 semibold — card title</span>
  <span style="font-family:'Nunito Sans';font-size:15px;font-weight:600">Bahar Manzarası 4K — Doğa Belgeseli.mp4</span></div>
<div class="type"><span class="spec">Nunito Sans 13.5 — body</span>
  <span style="font-family:'Nunito Sans';font-size:13.5px">Paste a link or drop an https:// address into the field.</span></div>
<div class="type"><span class="spec">Nunito Sans 11 caps — field label</span>
  <span style="font-family:'Nunito Sans';font-size:11px;font-weight:600;letter-spacing:.09em;text-transform:uppercase;color:#5F6660">Download folder</span></div>
<div class="type"><span class="spec">JetBrains Mono 12 — numbers</span>
  <span style="font-family:'JetBrains Mono';font-size:12px">557 MB / 1.4 GB • 2.4 MB/s • Time left: 6 m 12 s</span></div>

<h2>Shape</h2>
<div class="shapes">
${shape
  .map(
    (r) => `<div class="shape" style="border-radius:${r.value}px"><b>${r.value}</b><span>${r.name.replace("radius", "")}</span></div>`,
  )
  .join("\n")}
</div>

<h2>Window geometry</h2>
<div class="wins">
  <div class="win" style="width:640px;height:440px">1280 × 880<small>main — landscape</small></div>
  <div class="win" style="width:230px;height:300px">460 × 600<small>handoff</small></div>
  <div class="win" style="width:380px;height:200px">760 × 400<small>live download — landscape</small></div>
</div>
<div class="note">Shown at half scale above. The live download window is landscape on purpose: at 520 × 560 an
16-connection row left each bar ~26 px and the pill radius turned them into circles.</div>
</body></html>
`;

mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(HTML, html);

const browsers = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
];
const browser = browsers.find((p) => existsSync(p));
if (!browser) fail("ne Edge ne Chrome bulundu; PNG uretilemedi (HTML yazildi)");

execFileSync(
  browser,
  [
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    "--force-device-scale-factor=1",
    "--window-size=1400,3000",
    `--screenshot=${PNG}`,
    `file:///${HTML.replace(/\\/g, "/")}`,
  ],
  { stdio: "ignore", windowsHide: true },
);

console.log(`HTML: ${HTML}`);
console.log(`PNG : ${PNG}`);
console.log(`renk: ${light.length} acik + ${dark.length} koyu token, ${shape.length} yaricap`);
