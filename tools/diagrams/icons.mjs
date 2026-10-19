// Extract the official OCI icons from Oracle's draw.io toolkit into .cache/icons/<slug>.svg.
// The toolkit is downloaded from docs.oracle.com on the first run and never committed:
// https://docs.oracle.com/en-us/iaas/Content/General/Reference/graphicsfordiagrams.htm
// Most icons are draw.io stencils, so they are rendered to SVG with mxGraph in headless Chrome.
// Usage: node icons.mjs
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { execFileSync } from "node:child_process";
import puppeteer from "puppeteer";

const ZIP_URL = "https://docs.oracle.com/iaas/Content/Resources/Assets/OCI-Style-Guide-for-Drawio.zip";
const CACHE = path.resolve(import.meta.dirname, ".cache");
const OUT = path.join(CACHE, "icons");

// slug -> library title. "image:" icons are plain embedded SVGs (grouping badges, connectors).
const ICONS = {
  vm: "Compute - Virtual Machine VM",
  drg: "Networking - Dynamic Routing Gateway DRG",
  cpe: "Networking - Customer Premises Equipment CPE",
  datacenter: "Networking - Customer Data Center",
  lb: "Networking - Flexible Load Balancer",
  nlb: "Networking - Load Balancer",
  igw: "Networking - Internet Gateway",
  "route-table": "Networking - Route Table",
  "security-list": "Identity and Security - Security Lists",
  "flow-logs": "Observability and Management - VCN Flow Logs",
  logging: "Observability and Management - Logging",
  internet: "Cloud",
  user: "Identity and Security - User",
  "vcn-badge": "image:Physical - Grouping - VCN",
  "subnet-badge": "image:Physical - Grouping - Subnet",
  vpn: "image:Physical - Special Connectors - Site-to-site-VPN - Vertical",
};

if (fs.existsSync(OUT) && Object.keys(ICONS).every((s) => fs.existsSync(path.join(OUT, `${s}.svg`)))) {
  console.log("icons cached in", OUT);
  process.exit(0);
}

const zip = path.join(CACHE, "oci-drawio.zip");
if (!fs.existsSync(zip)) {
  fs.mkdirSync(CACHE, { recursive: true });
  const res = await fetch(ZIP_URL);
  if (!res.ok) throw new Error(`${ZIP_URL}: ${res.status}`);
  fs.writeFileSync(zip, Buffer.from(await res.arrayBuffer()));
}
execFileSync("unzip", ["-o", "-q", zip, "-d", path.join(CACHE, "drawio")]);
const libFile = execFileSync("find", [path.join(CACHE, "drawio"), "-name", "OCI Library.xml"]).toString().trim();
const lib = JSON.parse(fs.readFileSync(libFile, "utf8").match(/<mxlibrary>([\s\S]*)<\/mxlibrary>/)[1]);

const inflate = (b64) => decodeURIComponent(zlib.inflateRawSync(Buffer.from(b64, "base64")).toString());
const decodeXml = (x) => (x.trimStart().startsWith("<") ? x : inflate(x));

fs.mkdirSync(OUT, { recursive: true });
const stencils = {};
const models = {};
for (const [slug, spec] of Object.entries(ICONS)) {
  const title = spec.replace(/^image:/, "");
  const item = lib.find((i) => i.title === title);
  if (!item) throw new Error(`icon not found in the toolkit: ${title}`);
  let xml = decodeXml(item.xml);
  if (spec.startsWith("image:")) {
    const b64 = xml.match(/image=data:image\/svg\+xml,([A-Za-z0-9+/=]+)/)[1];
    let svg = Buffer.from(b64, "base64").toString();
    // Some have only a viewBox; give them a size so they scale predictably as <img>.
    if (!/<svg[^>]*\swidth=/.test(svg)) {
      const [, , w, h] = svg.match(/viewBox="([^"]+)"/)[1].split(/\s+/);
      svg = svg.replace(/<svg/, `<svg width="${w}" height="${h}"`);
    }
    fs.writeFileSync(path.join(OUT, `${slug}.svg`), svg);
    continue;
  }
  // mxGraph core doesn't know draw.io's inline stencil(...) shapes: register them by name.
  xml = xml.replace(/shape=stencil\(([^)]*)\)/g, (_, b64) => {
    const name = `ocist${Object.keys(stencils).length}`;
    stencils[name] = inflate(b64);
    return `shape=${name}`;
  });
  // draw.io writes data URIs without ";base64", which mxGraph's style parser would split anyway.
  xml = xml.replace(/image=data:image\/svg\+xml,([A-Za-z0-9+/=]+)/g, (_, b64) =>
    `image=data:image/svg+xml,${encodeURIComponent(Buffer.from(b64, "base64").toString())}`);
  // Drop the toolkit's text labels (the diagrams label icons themselves), and draw.io's "group"
  // style, which mxGraph core renders as a default blue rectangle.
  models[slug] = xml.replace(/ value="[^"]*"/g, ' value=""').replace(/style="group"/g, 'style="fillColor=none;strokeColor=none"');
}

const HTML = `<!doctype html><html><head><meta charset="utf-8">
<script>window.mxLoadResources = false; window.mxLoadStylesheets = false; window.mxBasePath = "https://unpkg.com/mxgraph@4.2.2/javascript/src";</script>
<script src="https://unpkg.com/mxgraph@4.2.2/javascript/mxClient.min.js"></script>
</head><body><div id="g"></div></body></html>`;

const browser = await puppeteer.launch({ headless: true });
const page = await browser.newPage();
await page.setContent(HTML, { waitUntil: "networkidle0" });
const svgs = await page.evaluate((stencils, models) => {
  for (const [name, xml] of Object.entries(stencils)) {
    mxStencilRegistry.addStencil(name, new mxStencil(mxUtils.parseXml(xml).documentElement));
  }
  const out = {};
  for (const [slug, xml] of Object.entries(models)) {
    const graph = new mxGraph(document.getElementById("g"));
    new mxCodec(mxUtils.parseXml(xml)).decode(mxUtils.parseXml(xml).documentElement, graph.getModel());
    const root = document.createElementNS(mxConstants.NS_SVG, "svg");
    root.setAttribute("xmlns", mxConstants.NS_SVG);
    root.setAttribute("xmlns:xlink", mxConstants.NS_XLINK);
    const g = document.createElementNS(mxConstants.NS_SVG, "g");
    root.appendChild(g);
    document.body.appendChild(root);
    new mxImageExport().drawState(graph.getView().getState(graph.getModel().getRoot()), new mxSvgCanvas2D(g));
    // Crop to what was actually drawn (the toolkit's cells include room for a label).
    const b = g.getBBox();
    root.setAttribute("width", b.width);
    root.setAttribute("height", b.height);
    root.setAttribute("viewBox", `${b.x} ${b.y} ${b.width} ${b.height}`);
    out[slug] = mxUtils.getXml(root);
    root.remove();
    graph.destroy();
  }
  return out;
}, stencils, models);
await browser.close();

for (const [slug, svg] of Object.entries(svgs)) {
  fs.writeFileSync(path.join(OUT, `${slug}.svg`), svg);
}
console.log("wrote", Object.keys(ICONS).length, "icons to", OUT);
