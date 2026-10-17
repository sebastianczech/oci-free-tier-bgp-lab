"""Generate the lab diagrams as Excalidraw scenes.

Writes diagrams/<name>.excalidraw; export.mjs turns them into .excalidraw.svg files
(scene embedded, editable in the VS Code Excalidraw extension) and <name>.png previews.
Run: cd tools/diagrams && npm install && npm run build   (python3 build.py <name> builds only matching ones)
"""
import base64
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "diagrams"

# Flow colours (see legend()).
INBOUND, OUTBOUND, EASTWEST, ONPREM, CONTROL = "#2f9e44", "#9c36b5", "#f08c00", "#c2255c", "#495057"
VNET_STROKE, VNET_BG = "#1971c2", "#e7f5ff"
SUBNET_STROKE, GREY_BG = "#868e96", "#f1f3f5"
OCI_RED, OCI_BG = "#c74634", "#fff4f0"  # Oracle-managed services (DRG, LB, NLB)
FAIL = "#c92a2a"

MIME = {".svg": "image/svg+xml", ".png": "image/png"}

class Node:
    """Bounding box of an icon plus its label, with anchor points for arrows."""

    def __init__(self, x, y, w, h, label_bottom):
        self.x, self.y, self.w, self.h = x, y, w, h
        self.cx, self.cy = x + w / 2, y + h / 2
        self.l, self.r = (x, self.cy), (x + w, self.cy)
        self.t, self.b = (self.cx, y), (self.cx, label_bottom)

    def at(self, side, dy=0, dx=0):
        px, py = getattr(self, side)
        return (px + dx, py + dy)


class Diagram:
    def __init__(self, name, out=OUT):
        self.name, self.out = name, out
        self.els, self.files = [], {}
        self.rng = random.Random(name)

    # -- low-level element factory -------------------------------------------------
    def _el(self, type_, x, y, w, h, **kw):
        e = dict(
            id=f"{self.name}-{type_}-{len(self.els)}", type=type_, x=x, y=y, width=w, height=h,
            angle=0, strokeColor="#1e1e1e", backgroundColor="transparent", fillStyle="solid",
            strokeWidth=2, strokeStyle="solid", roughness=1, opacity=100, groupIds=[],
            frameId=None, roundness=None, seed=self.rng.randint(1, 2**31),
            version=1, versionNonce=self.rng.randint(1, 2**31), isDeleted=False,
            boundElements=None, updated=1, link=None, locked=False,
        )
        e.update(kw)
        self.els.append(e)
        return e

    def _text(self, x, y, text, size=16, color="#1e1e1e", align="left", container=None):
        lines = text.split("\n")
        w = max(len(line) for line in lines) * size * 0.55
        h = len(lines) * size * 1.25
        t = self._el(
            "text", x, y, w, h, text=text, originalText=text, fontSize=size, fontFamily=2,
            textAlign=align, verticalAlign="middle" if container else "top",
            containerId=container["id"] if container else None, lineHeight=1.25,
            autoResize=True, strokeColor=color,
        )
        if container:
            container["boundElements"] = (container["boundElements"] or []) + [{"type": "text", "id": t["id"]}]
        return t

    def _label_box(self, cx, top, text, size=14, color="#1e1e1e", width=190):
        n = len(text.split("\n"))
        box = self._el("rectangle", cx - width / 2, top, width, n * size * 1.25 + 4,
                       strokeColor="transparent", strokeWidth=1)
        self._text(cx, top, text, size=size, color=color, align="center", container=box)
        return top + n * size * 1.25 + 4

    def _file(self, path):
        fid = path.stem + "-" + path.suffix[1:]
        if fid not in self.files:
            data = base64.b64encode(path.read_bytes()).decode()
            self.files[fid] = dict(id=fid, mimeType=MIME[path.suffix], created=1, lastRetrieved=1,
                                   dataURL=f"data:{MIME[path.suffix]};base64,{data}")
        return fid

    # -- building blocks -------------------------------------------------------------
    def box(self, x, y, w, h, label, stroke=VNET_STROKE, bg=VNET_BG, dashed=False, size=16):
        self._el("rectangle", x, y, w, h, strokeColor=stroke, backgroundColor=bg,
                 strokeStyle="dashed" if dashed else "solid", strokeWidth=1 if dashed else 2,
                 roundness={"type": 3})
        self._text(x + 10, y + 8, label, size=size, color=stroke)

    def subnet(self, x, y, w, h, label):
        self.box(x, y, w, h, label, stroke=SUBNET_STROKE, bg="transparent", dashed=True, size=13)

    def cloud(self, cx, cy, label, w=130, h=70):
        e = self._el("ellipse", cx - w / 2, cy - h / 2, w, h, backgroundColor=GREY_BG, strokeColor=SUBNET_STROKE)
        self._text(cx, cy, label, size=16, align="center", container=e)
        return Node(cx - w / 2, cy - h / 2, w, h, cy + h / 2)

    def router(self, cx, cy, label, w=140, h=84):
        e = self._el("rectangle", cx - w / 2, cy - h / 2, w, h, backgroundColor="#ffffff",
                     strokeColor="#1e1e1e", roundness={"type": 3})
        self._text(cx, cy, label, size=15, align="center", container=e)
        return Node(cx - w / 2, cy - h / 2, w, h, cy + h / 2)

    def service(self, cx, cy, label, w=170, h=84):
        """Oracle-managed service (DRG, load balancers): router shape in OCI red."""
        e = self._el("rectangle", cx - w / 2, cy - h / 2, w, h, backgroundColor=OCI_BG,
                     strokeColor=OCI_RED, roundness={"type": 3})
        self._text(cx, cy, label, size=15, color=OCI_RED, align="center", container=e)
        return Node(cx - w / 2, cy - h / 2, w, h, cy + h / 2)

    def note(self, x, y, text, size=13, color="#495057"):
        self._text(x, y, text, size=size, color=color)

    def arrow(self, points, color, label=None, dashed=False, both=False, width=2, heads=True):
        x0, y0 = points[0]
        rel = [[px - x0, py - y0] for px, py in points]
        xs, ys = [p[0] for p in rel], [p[1] for p in rel]
        a = self._el("arrow", x0, y0, max(xs) - min(xs), max(ys) - min(ys), points=rel,
                     strokeColor=color, strokeWidth=width, strokeStyle="dashed" if dashed else "solid",
                     lastCommittedPoint=None, startBinding=None, endBinding=None,
                     startArrowhead="arrow" if both and heads else None,
                     endArrowhead="arrow" if heads else None,
                     roundness=None, elbowed=False)
        if label:
            self._text(x0, y0, label, size=13, color=color, align="center", container=a)

    def legend(self, x, y, items):
        for i, (color, text, dashed, *heads) in enumerate(items):
            yy = y + i * 24
            self.arrow([(x, yy + 9), (x + 50, yy + 9)], color, dashed=dashed, heads=heads[0] if heads else True)
            self._text(x + 60, yy, text, size=13, color=color)

    def title(self, x, y, text, subtitle):
        self._text(x, y, text, size=22)
        self._text(x, y + 32, subtitle, size=14, color="#495057")

    def save(self):
        scene = dict(type="excalidraw", version=2, source="tools/diagrams/build.py",
                     elements=self.els, appState={"viewBackgroundColor": "#ffffff", "gridSize": None},
                     files=self.files)
        self.out.mkdir(parents=True, exist_ok=True)
        path = self.out / f"{self.name}.excalidraw"
        path.write_text(json.dumps(scene, indent=1))
        return path




def topology():
    d = Diagram("topology")
    d.title(40, 0, "OCI Always Free BGP lab · topology and packet flows",
            "4 VMs (2 × A1, 2 × Micro) · DRG + Site-to-Site VPN with BGP · private NLB as transparent next hop · public 10 Mbps LB")
    inet = d.cloud(640, 120, "Internet")

    d.box(30, 200, 1010, 640, "hub VCN 10.0.0.0/16")
    d.subnet(60, 250, 300, 220, "lb 10.0.0.0/24")
    lb = d.service(210, 360, "Public LB\nflexible, 10 Mbps")
    d.subnet(390, 250, 620, 300, "nva 10.0.1.0/24")
    r1 = d.router(560, 360, "router-1 .11\nA1 · FRR AS 65020", w=180)
    r2 = d.router(880, 360, "router-2 .12\nA1 · FRR AS 65020", w=180)
    nlb = d.service(700, 480, "private NLB .100\npreserve src/dst\nsymmetric hash · ANY/0", w=210)
    d.subnet(60, 600, 500, 210, "app 10.0.2.0/24")
    app = d.router(330, 705, "app .10\nMicro · nginx\nno public IP", w=160)
    d.note(600, 690, "Route tables\napp subnet: 0/0, 172.16/16, 192.168.100/24 → NLB\nnva subnet: 0/0 → IGW · on-prem → DRG\n"
                     "DRG attachment (ingress): 10.0.2.0/24 → NLB", color="#1e1e1e")
    d.note(600, 775, "Routers SNAT app → internet,\nso no NAT gateway is needed.", color=OUTBOUND)

    drg = d.service(1120, 640, "DRG\nAS 31898", w=130)
    d.arrow([drg.l, (1040, 640)], "#1e1e1e", heads=False, width=1)
    d.note(1060, 690, "VCN attachment\n+ ingress RT", size=12)

    d.box(1200, 200, 350, 330, "onprem VCN 172.16.0.0/16")
    d.subnet(1225, 250, 300, 260, "dc 172.16.0.0/24")
    cpe = d.router(1375, 390, "cpe .10 · Micro\nLibreswan + FRR\nAS 65010\nlo 192.168.100.1/24", w=200, h=100)

    # VPN: tunnels over the internet, BGP inside them
    d.arrow([drg.at("r", 12), (1395, 652), (1395, cpe.b[1])], ONPREM, width=4, heads=False)
    d.note(1405, 560, "2 × IPSec tunnels\nIKEv2 · NAT-T\n(over the internet)", color=ONPREM, size=12)
    d.arrow([drg.at("r", -12), (1355, 628), (1355, cpe.b[1])], CONTROL, dashed=True, both=True)
    d.note(1200, 545, "eBGP 31898 ↔ 65010\n169.254.10.0/30\n169.254.20.0/30", color=CONTROL, size=12)

    # Inbound: internet -> public LB -> app
    d.arrow([inet.l, (210, 120), lb.t], INBOUND)
    d.arrow([lb.b, (210, 705), app.l], INBOUND)
    # Outbound: app -> NLB -> router-1 (SNAT) -> IGW -> internet
    d.arrow([app.at("t", dx=20), (350, 480), nlb.l], OUTBOUND)
    d.arrow([nlb.at("t", dx=-50), r1.at("b", dx=30)], OUTBOUND)
    d.arrow([r1.t, (560, 190), (610, 190), (610, inet.b[1])], OUTBOUND)
    d.note(570, 205, "IGW", size=12, color=OUTBOUND)
    # On-prem -> app: DRG -> ingress RT -> NLB -> router-2 -> app
    d.arrow([drg.at("l", -10), (960, 630), (960, 480), nlb.r], ONPREM)
    d.arrow([nlb.at("t", dx=50), r2.at("b", dx=-30)], ONPREM)
    d.arrow([r2.at("b", dx=20), (900, 575), (450, 575), (450, 705), app.r], ONPREM)

    d.legend(40, 870, [(INBOUND, "inbound: internet → public LB → app", False),
                       (OUTBOUND, "outbound: app → NLB → router (SNAT) → IGW → internet", False),
                       (ONPREM, "on-prem ↔ app: cpe → tunnel → DRG → NLB → router → app (reply: same router)", False),
                       (CONTROL, "BGP", True)])
    return d


def bgp_sessions():
    d = Diagram("bgp-sessions")
    d.title(40, 0, "BGP sessions · and why VM BGP doesn't change OCI routing",
            "cpe peers with the DRG (programs OCI) and, multihop through the VPN, with both routers (programs only the VMs)")
    rt = d.service(720, 140, "DRG route table\n172.16.0.0/24, 192.168.100.0/24 → IPSec\nno route for 10.255.0.0/24", w=330, h=80)
    cpe = d.router(250, 330, "cpe 172.16.0.10\nAS 65010\nlo 192.168.100.1/24", w=220, h=110)
    drg = d.service(720, 330, "DRG\nAS 31898", w=150)
    r1 = d.router(1180, 220, "router-1 10.0.1.11\nAS 65020\nlo 10.255.0.1/32", w=220, h=100)
    r2 = d.router(1180, 450, "router-2 10.0.1.12\nAS 65020\nlo 10.255.0.2/32", w=220, h=100)

    d.arrow([drg.t, rt.b], INBOUND, heads=True)
    d.note(730, 255, "programs", size=12, color=INBOUND)
    d.arrow([cpe.at("r", -20), drg.at("l", -20)], CONTROL, "tunnel 1 · 169.254.10.0/30", dashed=True, both=True)
    d.arrow([cpe.at("r", 20), drg.at("l", 20)], CONTROL, "tunnel 2 · 169.254.20.0/30", dashed=True, both=True)
    d.note(375, 240, "→ 172.16.0.0/24, 192.168.100.0/24\n   (prefix-list ONPREM)", size=12)
    d.note(375, 380, "← 10.0.0.0/16 (VCN)", size=12)

    d.arrow([cpe.b, (250, 620), (960, 620), (960, 450), r2.l], CONTROL, dashed=True, both=True)
    d.arrow([(960, 450), (960, 220), r1.l], CONTROL, dashed=True)
    d.note(270, 630, "eBGP multihop 65010 ↔ 65020 · TCP 179 runs inside the VPN: cpe → DRG → hub VCN → router", color=CONTROL)
    d.note(1075, 515, "→ 10.255.0.1/32, 10.255.0.2/32", size=12)

    d.note(380, 455, "ping 10.255.0.1 from cpe  ✗\ncpe: 10.255.0.1 via 10.0.1.11 → vti → DRG\nDRG: no route for 10.255.0.0/24 → drop\n"
                     "BGP between VMs only changes the VMs' own tables.\nOCI has no Azure Route Server equivalent.", color=FAIL)
    d.legend(40, 690, [(CONTROL, "BGP session", True), (INBOUND, "DRG installs BGP routes", False)])
    return d


DIAGRAMS = [topology, bgp_sessions]

if __name__ == "__main__":
    wanted = set(sys.argv[1:])
    for fn in DIAGRAMS:
        d = fn()
        if not wanted or any(w in d.name for w in wanted):
            print(d.save())
