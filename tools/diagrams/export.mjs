// Render .excalidraw scene files to .excalidraw.svg (scene embedded, so the
// VS Code Excalidraw extension can still edit them) and optional PNG previews.
// Usage: node export.mjs <scene.excalidraw>... [--png-dir DIR]
import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer";

const args = process.argv.slice(2);
const pngIdx = args.indexOf("--png-dir");
const pngDir = pngIdx >= 0 ? args.splice(pngIdx, 2)[1] : null;

const HTML = `<!doctype html><html><head><meta charset="utf-8">
<script src="https://unpkg.com/react@18.2.0/umd/react.production.min.js"></script>
<script src="https://unpkg.com/react-dom@18.2.0/umd/react-dom.production.min.js"></script>
<script src="https://unpkg.com/@excalidraw/excalidraw@0.17.6/dist/excalidraw.production.min.js"></script>
</head><body></body></html>`;

const browser = await puppeteer.launch({ headless: true });
const page = await browser.newPage();
await page.setContent(HTML, { waitUntil: "networkidle0" });
await page.waitForFunction(() => window.ExcalidrawLib?.exportToSvg);

for (const file of args) {
  const scene = JSON.parse(fs.readFileSync(file, "utf8"));
  const { svg, png } = await page.evaluate(async (scene, wantPng) => {
    const L = window.ExcalidrawLib;
    // Recompute text dimensions with the real font metrics.
    const elements = L.restoreElements(scene.elements, null, { refreshDimensions: true });
    // Static export doesn't re-layout bound text, so centre it on its container
    // (shape centre, or the half-length point of an arrow).
    const byId = new Map(elements.map((e) => [e.id, e]));
    for (const t of elements) {
      const c = t.type === "text" && t.containerId && byId.get(t.containerId);
      if (!c) continue;
      let cx = c.x + c.width / 2, cy = c.y + c.height / 2;
      if (c.type === "arrow") {
        const pts = c.points.map(([px, py]) => [c.x + px, c.y + py]);
        const lens = pts.slice(1).map((p, i) => Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]));
        let rest = lens.reduce((a, b) => a + b, 0) / 2;
        for (let i = 0; i < lens.length; i++) {
          if (rest <= lens[i]) {
            const f = lens[i] ? rest / lens[i] : 0;
            cx = pts[i][0] + f * (pts[i + 1][0] - pts[i][0]);
            cy = pts[i][1] + f * (pts[i + 1][1] - pts[i][1]);
            break;
          }
          rest -= lens[i];
        }
      }
      t.x = cx - t.width / 2;
      t.y = cy - t.height / 2;
    }
    const appState = { ...scene.appState, exportEmbedScene: true, exportBackground: true };
    const svgEl = await L.exportToSvg({ elements, appState, files: scene.files });
    let png = null;
    if (wantPng) {
      const blob = await L.exportToBlob({ elements, appState: { ...appState, exportEmbedScene: false }, files: scene.files, mimeType: "image/png", exportPadding: 20 });
      png = await new Promise((r) => { const fr = new FileReader(); fr.onload = () => r(fr.result); fr.readAsDataURL(blob); });
    }
    return { svg: svgEl.outerHTML, png };
  }, scene, Boolean(pngDir));

  const out = file.replace(/\.excalidraw$/, ".excalidraw.svg");
  fs.writeFileSync(out, svg);
  console.log("wrote", out);
  if (pngDir && png) {
    const pngOut = path.join(pngDir, path.basename(file, ".excalidraw") + ".png");
    fs.writeFileSync(pngOut, Buffer.from(png.split(",")[1], "base64"));
  }
}
await browser.close();
