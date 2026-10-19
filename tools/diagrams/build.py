"""Generate the lab diagrams as Excalidraw scenes, with the official OCI icons.

Writes diagrams/<name>.excalidraw; export.mjs turns them into .excalidraw.svg files
(scene embedded, editable in the VS Code Excalidraw extension) and <name>.png previews.
The icons come from Oracle's OCI Architecture Diagram Toolkit: icons.mjs extracts them
into .cache/icons/ (downloaded on the first build, not committed).
Run: cd tools/diagrams && npm install && npm run build   (python3 build.py <name> builds only matching ones)
"""
import base64
import json
import random
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "diagrams"
ICONS = Path(__file__).resolve().parent / ".cache" / "icons"

# Flow colours (see legend()).
INBOUND, OUTBOUND, EASTWEST, ONPREM, CONTROL = "#2f9e44", "#9c36b5", "#f08c00", "#c2255c", "#495057"
FAIL = "#c92a2a"
# OCI toolkit grouping styles: region / on-prem (grey fill), VCN and subnet (dashed, OCI orange).
REGION_STROKE, REGION_BG, OCI_TEXT = "#9e9892", "#f5f4f2", "#312d2a"
VCN_STROKE = "#ae562c"
NOTE = "#495057"

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

    def _image(self, slug, x, y, h):
        path = ICONS / f"{slug}.svg"
        if not path.exists():
            sys.exit(f"{path} missing: run `node icons.mjs` (npm run build does it)")
        head = path.read_text()[:2000]
        iw, ih = (float(re.search(rf'<svg[^>]*\s{a}="([\d.]+)', head, re.S).group(1)) for a in ("width", "height"))
        w = h * iw / ih
        self._el("image", x, y, w, h, fileId=self._file(path), status="saved", scale=[1, 1],
                 strokeColor="transparent", roughness=0)
        return w

    # -- building blocks -------------------------------------------------------------
    def icon(self, slug, cx, cy, label=None, h=56, color="#1e1e1e", width=200, size=14):
        """Official OCI icon centred on (cx, cy), with an optional label below it."""
        w = self._image(slug, 0, cy - h / 2, h)
        self.els[-1]["x"] = cx - w / 2
        bottom = self._label_box(cx, cy + h / 2 + 4, label, size=size, color=color, width=width) if label else cy + h / 2
        return Node(cx - w / 2, cy - h / 2, w, h, bottom)

    def region(self, x, y, w, h, label):
        """Grey grouping from the OCI toolkit: an OCI region, on-premises, the internet."""
        self._el("rectangle", x, y, w, h, strokeColor=REGION_STROKE, backgroundColor=REGION_BG,
                 strokeWidth=1, roundness={"type": 3}, roughness=0)
        self._text(x + 12, y + 8, label, size=16, color=OCI_TEXT)

    def vcn(self, x, y, w, h, label):
        self._el("rectangle", x, y, w, h, strokeColor=VCN_STROKE, backgroundColor="#ffffff",
                 strokeStyle="dashed", strokeWidth=2, roughness=0)
        self._image("vcn-badge", x + 8, y + 8, 26)
        self._text(x + 42, y + 12, label, size=16, color=VCN_STROKE)

    def subnet(self, x, y, w, h, label):
        self._el("rectangle", x, y, w, h, strokeColor=VCN_STROKE, backgroundColor="transparent",
                 strokeStyle="dashed", strokeWidth=1, roughness=0)
        self._image("subnet-badge", x + 8, y + 8, 22)
        self._text(x + 34, y + 11, label, size=13, color=VCN_STROKE)

    def card(self, x, y, w, h, text, color=NOTE, bg="#ffffff", size=13):
        """Rounded note box, for route tables and BGP policy."""
        e = self._el("rectangle", x, y, w, h, strokeColor=color, backgroundColor=bg, strokeWidth=1,
                     roundness={"type": 3}, roughness=0)
        self._text(x + w / 2, y + h / 2, text, size=size, color=color, align="center", container=e)
        return Node(x, y, w, h, y + h)

    def step(self, n, cx, cy, color):
        e = self._el("ellipse", cx - 13, cy - 13, 26, 26, strokeColor=color, backgroundColor=color, roughness=0)
        self._text(cx, cy, str(n), size=14, color="#ffffff", align="center", container=e)

    def note(self, x, y, text, size=13, color=NOTE):
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
        self._text(x, y + 32, subtitle, size=14, color=NOTE)

    def save(self):
        scene = dict(type="excalidraw", version=2, source="tools/diagrams/build.py",
                     elements=self.els, appState={"viewBackgroundColor": "#ffffff", "gridSize": None},
                     files=self.files)
        self.out.mkdir(parents=True, exist_ok=True)
        path = self.out / f"{self.name}.excalidraw"
        path.write_text(json.dumps(scene, indent=1))
        return path


def topology():
    """README and article 1: the whole lab."""
    d = Diagram("topology")
    d.title(40, 0, "OCI Always Free BGP lab", "2 Micro VMs · Site-to-Site VPN with BGP · public LB and private NLB")
    you = d.icon("user", 130, 140, "you", h=48)
    inet = d.icon("internet", 420, 140, "Internet", h=40)
    d.arrow([you.r, inet.l], INBOUND)

    d.region(20, 220, 1150, 560, "OCI region")
    d.vcn(40, 262, 1000, 500, "hub VCN 10.0.0.0/16")
    igw = d.icon("igw", 420, 262, None, h=46)
    d.note(450, 266, "IGW", color=VCN_STROKE)
    d.subnet(60, 330, 290, 250, "lb 10.0.0.0/24")
    lb = d.icon("lb", 255, 450, "Public LB", h=56)
    d.subnet(380, 330, 640, 250, "nva 10.0.1.0/24")
    r1 = d.icon("vm", 560, 450, "router-1 .11\nFRR · nginx", h=56)
    nlb = d.icon("nlb", 870, 450, "Private NLB .100", h=56)

    drg = d.icon("drg", 1100, 680, "DRG", h=60, width=110)
    d.arrow([drg.l, (1040, 680)], "#1e1e1e", heads=False, width=1)

    d.region(1220, 220, 400, 560, "Simulated on-prem")
    d.vcn(1240, 262, 360, 300, "onprem VCN 172.16.0.0/16")
    d.subnet(1260, 330, 320, 210, "dc 172.16.0.0/24")
    cpe = d.icon("cpe", 1420, 430, "cpe .10\nLibreswan · FRR", h=56)

    # VPN: tunnels over the internet, BGP inside them
    d.arrow([drg.at("r", 10), (1440, 690), (1440, cpe.b[1] + 6)], ONPREM, width=4, heads=False)
    d.icon("vpn", 1440, 630, None, h=34)
    d.note(1462, 640, "2 × IPSec", color=ONPREM)
    d.arrow([drg.at("r", -10), (1395, 670), (1395, cpe.b[1] + 6)], CONTROL, dashed=True, both=True)
    d.note(1300, 600, "BGP", color=CONTROL)

    # Inbound: internet -> IGW -> public LB -> nginx on router-1
    d.arrow([inet.at("b", 0, -10), (410, igw.t[1])], INBOUND, heads=False)
    d.arrow([(410, igw.y + igw.h), (410, 310), (255, 310), lb.t], INBOUND)
    d.arrow([lb.r, r1.l], INBOUND)
    # Outbound: router-1's own traffic -> IGW -> internet
    d.arrow([r1.t, (560, 300), (432, 300), (432, igw.y + igw.h)], OUTBOUND, heads=False)
    d.arrow([(432, igw.t[1]), inet.at("b", 0, 12)], OUTBOUND)
    # On-prem -> web: tunnel -> DRG -> NLB -> router-1:80
    d.arrow([drg.at("l", -12), (960, 668), (960, 560), (870, 560), nlb.b], ONPREM)
    d.arrow([nlb.l, r1.r], ONPREM)

    d.legend(40, 810, [(INBOUND, "internet → LB → router-1", False),
                       (OUTBOUND, "router-1 → internet", False),
                       (ONPREM, "on-prem → NLB → router-1", False),
                       (CONTROL, "BGP", True)])
    return d


def vpn_tunnels():
    """Article 2: two route-based tunnels from the cpe VM to the OCI VPN headends."""
    d = Diagram("vpn-tunnels")
    d.title(40, 0, "Site-to-Site VPN", "two route-based IPSec tunnels, BGP inside each")
    d.region(20, 90, 520, 400, "Simulated on-prem")
    d.vcn(40, 132, 480, 340, "onprem VCN")
    cpe = d.icon("cpe", 150, 300, "cpe\n172.16.0.10", h=64)
    d.card(280, 210, 200, 54, "vti1\n169.254.21.2", color=ONPREM)
    d.card(280, 340, 200, 54, "vti2\n169.254.22.2", color=ONPREM)
    d.arrow([cpe.at("r", -10), (280, 237)], ONPREM, heads=False)
    d.arrow([cpe.at("r", 10), (280, 367)], ONPREM, heads=False)

    nat = d.icon("igw", 700, 300, "1:1 NAT", h=50)
    d.arrow([(480, 237), (620, 237), (620, 290), nat.l], ONPREM, width=3, heads=False)
    d.arrow([(480, 367), (620, 367), (620, 310), nat.l], ONPREM, width=3, heads=False)
    inet = d.icon("internet", 880, 300, "Internet", h=40)
    d.arrow([nat.r, inet.l], ONPREM, width=4, heads=False)
    d.note(790, 380, "ESP in UDP 4500", color=ONPREM)

    d.region(1000, 90, 560, 400, "OCI region")
    h1 = d.icon("vpn", 1120, 220, "tunnel 1\n169.254.21.1", h=48)
    h2 = d.icon("vpn", 1120, 380, "tunnel 2\n169.254.22.1", h=48)
    d.arrow([inet.at("r", -6), (960, 294), (960, 220), h1.l], ONPREM, width=4, heads=False)
    d.arrow([inet.at("r", 6), (960, 306), (960, 380), h2.l], ONPREM, width=4, heads=False)
    drg = d.icon("drg", 1420, 300, "DRG", h=64, width=120)
    d.arrow([h1.r, (1340, 220), (1340, 290), drg.at("l", -10)], ONPREM, width=3, heads=False)
    d.arrow([h2.r, (1340, 380), (1340, 310), drg.at("l", 10)], ONPREM, width=3, heads=False)
    d.arrow([(cpe.cx, cpe.y - 4), (cpe.cx, 190), (1420, 190), drg.t], CONTROL, dashed=True, both=True)

    d.legend(40, 520, [(ONPREM, "IPSec", False, False), (CONTROL, "BGP inside the tunnels", True)])
    return d


def bgp_sessions():
    """README and article 3: the three BGP sessions and why VM BGP doesn't change OCI routing."""
    d = Diagram("bgp-sessions")
    d.title(40, 0, "BGP sessions", "only the DRG sessions change OCI routing")
    rt = d.icon("route-table", 720, 120, "DRG route table\nno 10.255.0.0/24", h=46)
    cpe = d.icon("cpe", 250, 330, "cpe\nAS 65010", h=60)
    drg = d.icon("drg", 720, 330, "DRG\nAS 31898", h=64, width=120)
    r1 = d.icon("vm", 1180, 330, "router-1\nAS 65020\nlo 10.255.0.1", h=60)

    d.arrow([drg.t, (720, rt.b[1] + 4)], INBOUND)
    d.arrow([cpe.at("r", -16), drg.at("l", -16)], CONTROL, "tunnel 1", dashed=True, both=True)
    d.arrow([cpe.at("r", 16), drg.at("l", 16)], CONTROL, "tunnel 2", dashed=True, both=True)

    d.arrow([(250, cpe.b[1] + 6), (250, 560), (1180, 560), (1180, r1.b[1] + 6)], CONTROL, "eBGP multihop through the VPN",
            dashed=True, both=True)
    d.note(560, 450, "ping 10.255.0.1 ✗", size=16, color=FAIL)
    d.legend(40, 620, [(CONTROL, "BGP session", True), (INBOUND, "DRG installs routes", False)])
    return d


def bgp_policy():
    """Article 3: the route-maps on every eBGP session (RFC 8212: no policy, no routes)."""
    d = Diagram("bgp-policy")
    d.title(40, 0, "eBGP policy", "every eBGP neighbor has an in and an out route-map")
    drg = d.icon("drg", 150, 300, "DRG", h=64, width=120)
    cpe = d.icon("cpe", 720, 300, "cpe", h=64)
    r1 = d.icon("vm", 1290, 300, "router-1", h=64)

    d.arrow([(drg.r[0] + 20, 280), (cpe.l[0] - 20, 280)], CONTROL, dashed=True)
    d.card(470, 170, 180, 50, "in FROM-OCI", color=INBOUND, bg="#ebfbee")
    d.arrow([(cpe.l[0] - 20, 320), (drg.r[0] + 20, 320)], CONTROL, dashed=True)
    d.card(470, 380, 180, 50, "out ONPREM-ONLY", color=OUTBOUND, bg="#f8f0fc")

    d.arrow([(r1.l[0] - 20, 280), (cpe.r[0] + 20, 280)], CONTROL, dashed=True)
    d.card(790, 170, 180, 50, "in FROM-ROUTERS", color=INBOUND, bg="#ebfbee")
    d.card(1060, 170, 180, 50, "out TO-CPE", color=OUTBOUND, bg="#f8f0fc")
    d.arrow([(cpe.r[0] + 20, 320), (r1.l[0] - 20, 320)], CONTROL, dashed=True)
    d.card(790, 380, 180, 50, "out ONPREM-ONLY", color=OUTBOUND, bg="#f8f0fc")
    d.card(1060, 380, 180, 50, "in FROM-CPE", color=INBOUND, bg="#ebfbee")

    d.legend(40, 480, [(CONTROL, "BGP updates", True), (INBOUND, "accept", False, False),
                       (OUTBOUND, "send", False, False)])
    return d


def bgp_prepend():
    """Article 3: steer traffic from OCI onto tunnel 1 with AS-path prepending."""
    d = Diagram("bgp-prepend")
    d.title(40, 0, "AS-path prepending", "the DRG picks the shorter AS path")
    r1 = d.icon("vm", 130, 330, "router-1", h=56)
    drg = d.icon("drg", 520, 330, "DRG", h=64, width=110)
    cpe = d.icon("cpe", 1130, 330, "cpe", h=60)

    d.arrow([r1.r, drg.l], ONPREM, width=3)
    d.arrow([drg.at("r", -18), (720, 312), (720, 220), (940, 220), (940, 312), cpe.at("l", -18)], ONPREM, width=4)
    d.arrow([drg.at("r", 18), (720, 348), (720, 440), (940, 440), (940, 348), cpe.at("l", 18)], "#adb5bd", width=2, heads=False)
    d.note(745, 160, "tunnel 1 · AS path 65010", color=ONPREM, size=15)
    d.note(745, 455, "tunnel 2 · AS path 65010 65010 65010", color="#868e96", size=15)
    d.legend(40, 540, [(ONPREM, "traffic to on-prem", False), ("#adb5bd", "backup", False, False)])
    return d


def drg_routing():
    """Article 4: the three places a packet to router-1's loopback needs a route."""
    d = Diagram("drg-routing")
    d.title(40, 0, "Why ping 10.255.0.1 fails", "three places in OCI need a route")
    cpe = d.icon("cpe", 120, 330, "cpe", h=60)
    drg = d.icon("drg", 520, 330, "DRG", h=64, width=110)
    d.vcn(760, 90, 680, 470, "hub VCN")
    r1 = d.icon("vm", 1280, 330, "router-1\nlo 10.255.0.1", h=60)

    d.arrow([cpe.r, (drg.l[0] - 8, 330)], ONPREM, width=3)
    d.note(250, 300, "IPSec", color=ONPREM)
    d.arrow([(drg.r[0] + 8, 330), (r1.l[0] - 10, 330)], ONPREM, width=3, dashed=True)

    d.card(400, 140, 240, 64, "DRG route table\n10.255.0.0/24 → ?", color=FAIL)
    d.step(1, 400, 140, FAIL)
    d.arrow([(520, 206), (520, drg.y - 4)], FAIL, heads=False, width=1)
    d.card(840, 420, 260, 64, "VCN ingress route table\nempty", color=EASTWEST)
    d.step(2, 840, 420, EASTWEST)
    d.card(1180, 150, 200, 64, "router-1 VNIC\nsrc/dst check on", color=EASTWEST)
    d.step(3, 1180, 150, EASTWEST)
    d.legend(40, 600, [(ONPREM, "packet from on-prem", False), (FAIL, "dropped today", False, False),
                       (EASTWEST, "also needs a change", False, False)])
    return d


def lb_flows():
    """Article 5: which source IP router-1 sees behind each load balancer."""
    d = Diagram("lb-flows")
    d.title(40, 0, "Who sees which source IP", "both load balancers replace the client's source address")
    d.vcn(440, 80, 1060, 560, "hub VCN")

    you = d.icon("user", 120, 220, "client", h=56)
    lb = d.icon("lb", 650, 220, "Public LB", h=60)
    r1 = d.icon("vm", 1250, 380, "router-1", h=64)
    cpe = d.icon("cpe", 120, 540, "cpe", h=56)
    nlb = d.icon("nlb", 750, 540, "Private NLB", h=60)

    d.arrow([you.r, lb.l], INBOUND, width=3)
    d.note(240, 180, "src client", color=INBOUND, size=15)
    d.arrow([lb.r, (1250, 220), (1250, r1.y - 6)], INBOUND, width=3)
    d.note(860, 180, "src LB private IP", color=INBOUND, size=15)

    d.arrow([cpe.r, nlb.l], ONPREM, width=3)
    d.note(240, 500, "src 172.16.0.10", color=ONPREM, size=15)
    d.arrow([nlb.r, (1250, 540), (1250, r1.b[1] + 6)], ONPREM, width=3)
    d.note(880, 500, "src 10.0.1.100 (NLB)", color=ONPREM, size=15)

    d.icon("flow-logs", 1050, 380, "flow logs", h=46)
    d.legend(40, 680, [(INBOUND, "internet → public LB", False), (ONPREM, "on-prem → NLB", False)])
    return d


DIAGRAMS = [topology, vpn_tunnels, bgp_sessions, bgp_policy, bgp_prepend, drg_routing, lb_flows]

if __name__ == "__main__":
    wanted = set(sys.argv[1:])
    for fn in DIAGRAMS:
        d = fn()
        if not wanted or any(w in d.name for w in wanted):
            print(d.save())
