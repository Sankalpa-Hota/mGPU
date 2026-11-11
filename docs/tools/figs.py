import re, html

def esc(s):
    s = html.escape(s.strip())
    s = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", s)

def node_html(text):
    parts = [p.strip() for p in text.split("|")]
    label = parts[0]
    note = parts[1] if len(parts) > 1 else ""
    kind = parts[2] if len(parts) > 2 else ""
    cls = "tn " + kind
    out = f'<span class="{cls}">{esc(label)}</span>'
    if note:
        out += f'<span class="tnote">{esc(note)}</span>'
    return out

def tree(body):
    items = []
    for line in body.split("\n"):
        if not line.strip():
            continue
        depth = (len(line) - len(line.lstrip(" "))) // 2
        items.append((depth, line.strip()))
    out = ['<div class="treebox"><ul class="tree">']
    cur = 0
    first = True
    for depth, text in items:
        if first:
            out.append("<li>" + node_html(text))
            first = False
            cur = depth
            continue
        if depth > cur:
            out.append("<ul>" * (depth - cur))
        else:
            out.append("</li>")
            for _ in range(cur - depth):
                out.append("</ul></li>")
        if depth <= cur or True:
            out.append("<li>" + node_html(text))
        cur = depth
    out.append("</li>")
    out.append("</ul></li>" * cur)
    out.append("</ul></div>")
    return "".join(out)

def box(text):
    parts = [p.strip() for p in text.split("|")]
    kind = parts[2] if len(parts) > 2 else ""
    sub = f'<div class="fsub">{esc(parts[1])}</div>' if len(parts) > 1 and parts[1] else ""
    return f'<div class="fbox {kind}"><div class="ftitle">{esc(parts[0])}</div>{sub}</div>'

def flow(body):
    out = ['<div class="flowbox">']
    for line in body.split("\n"):
        line = line.strip()
        if not line:
            continue
        key, _, rest = line.partition(":")
        key = key.strip()
        if key == "box":
            out.append(box(rest))
        elif key == "row":
            cells = "".join(box(c) for c in rest.split(";;"))
            out.append(f'<div class="frow">{cells}</div>')
        elif key == "arrow":
            lab = f'<span class="flab">{esc(rest)}</span>' if rest.strip() else ""
            out.append(f'<div class="farrow"><span class="fline"></span>{lab}</div>')
        elif key == "back":
            out.append(f'<div class="fback">&#8592; {esc(rest)}</div>')
    out.append("</div>")
    return "".join(out)

def hflow(body):
    out = ['<div class="hflowbox">']
    for line in body.split("\n"):
        line = line.strip()
        if not line:
            continue
        cells = re.split(r"\s+-([^>]*?)->\s+", line)
        row = []
        for k, c in enumerate(cells):
            if k % 2 == 0:
                row.append(box(c))
            else:
                lab = f'<span class="hlab">{esc(c)}</span>' if c.strip() else ""
                row.append(f'<div class="harrow">{lab}<span class="hline"></span></div>')
        out.append('<div class="hrow">' + "".join(row) + "</div>")
    out.append("</div>")
    return "".join(out)

def pins(body):
    name, sub, ins, outs = "", "", [], []
    for line in body.split("\n"):
        line = line.strip()
        if not line:
            continue
        key, _, rest = line.partition(":")
        parts = [p.strip() for p in rest.split("|")]
        while len(parts) < 3:
            parts.append("")
        if key.strip() == "block":
            name, sub = parts[0], parts[1]
        elif key.strip() == "in":
            ins.append(parts)
        elif key.strip() == "out":
            outs.append(parts)
    def pin(p, side):
        sig = f'<div class="psig">{esc(p[0])}</div>'
        peer = f'<div class="ppeer">{esc(p[1])}</div>' if p[1] else ""
        desc = f'<div class="pdesc">{esc(p[2])}</div>' if p[2] else ""
        arrow = '<div class="parr"><span class="hline"></span></div>'
        text = f'<div class="ptext">{peer}{sig}{desc}</div>'
        return f'<div class="pin {side}">' + (text + arrow if side == "l" else arrow + text) + "</div>"
    left = "".join(pin(p, "l") for p in ins)
    right = "".join(pin(p, "r") for p in outs)
    mid = f'<div class="pblock"><div class="pname">{esc(name)}</div><div class="psub">{esc(sub)}</div></div>'
    return f'<div class="pinbox"><div class="pcol">{left}</div>{mid}<div class="pcol">{right}</div></div>'

def table_code(text):
    out = []
    fence = False
    for line in text.split("\n"):
        if line.startswith("```"):
            fence = not fence
        if not fence and line.startswith("|"):
            def fix(m):
                body = m.group(1).replace("\\|", "|")
                body = html.escape(body).replace("|", "&#124;")
                return "<code>" + body + "</code>"
            line = re.sub(r"`([^`]*)`", fix, line)
        out.append(line)
    return "\n".join(out)

def preprocess(text):
    text = table_code(text)
    text = re.sub(r"```tree\n(.*?)```", lambda m: "\n" + tree(m.group(1)) + "\n", text, flags=re.S)
    text = re.sub(r"```flow\n(.*?)```", lambda m: "\n" + flow(m.group(1)) + "\n", text, flags=re.S)
    text = re.sub(r"```pins\n(.*?)```", lambda m: "\n" + pins(m.group(1)) + "\n", text, flags=re.S)
    text = re.sub(r"```hflow\n(.*?)```", lambda m: "\n" + hflow(m.group(1)) + "\n", text, flags=re.S)
    return text

CSS = """
.treebox { margin: 2mm 0 3mm; font-size: 8.6pt; break-inside: avoid; }
.tree, .tree ul { list-style: none; margin: 0; padding: 0; }
.tree ul { margin-left: 5mm; }
.tree li { position: relative; padding: 1.1mm 0 0 6mm; }
.tree > li { padding-left: 0; }
.tree ul > li::before { content: ""; position: absolute; left: 0; top: 0; bottom: 0; border-left: 1.4px solid #9fb3c8; }
.tree ul > li:last-child::before { bottom: auto; height: 4.2mm; }
.tree ul > li::after { content: ""; position: absolute; left: 0; top: 4.2mm; width: 5mm; border-top: 1.4px solid #9fb3c8; }
.tn { display: inline-block; padding: 0.7mm 2.2mm; border-radius: 3px; border: 1px solid #b9c8d8; background: #f4f7fb; font-weight: 600; color: #1d2b3a; font-family: Menlo, monospace; font-size: 8.2pt; }
.tn.hw   { background: #fff4e5; border-color: #f0c27a; }
.tn.comp { background: #e8f1fc; border-color: #8fb4e3; }
.tn.obj  { background: #eaf7ee; border-color: #8ccaa0; }
.tn.dir  { background: #fff8d9; border-color: #e3cf73; }
.tn.file { background: #fff; border-color: #ccd6e0; font-weight: 500; }
.tn.root { background: #1f4e8c; border-color: #1f4e8c; color: #fff; }
.tnote { color: #5a6b7d; margin-left: 2.5mm; font-size: 8.2pt; }
.flowbox { display: flex; flex-direction: column; align-items: center; margin: 2mm 0 3mm; break-inside: avoid; font-size: 8.6pt; }
.fbox { border: 1.3px solid #8fb4e3; background: #eef4fc; border-radius: 4px; padding: 1.2mm 3mm; text-align: center; min-width: 52mm; max-width: 130mm; }
.fbox.hw { background: #fff4e5; border-color: #f0c27a; }
.fbox.ok { background: #eaf7ee; border-color: #8ccaa0; }
.fbox.bad { background: #fdeceb; border-color: #e59a94; }
.fbox.you { background: #1f4e8c; border-color: #1f4e8c; color: #fff; }
.fbox.you .fsub { color: #dbe7f6; }
.ftitle { font-weight: 700; }
.fsub { color: #4f6072; font-size: 8pt; margin-top: 0.4mm; }
.frow { display: flex; gap: 3mm; justify-content: center; }
.frow .fbox { min-width: 34mm; }
.farrow { position: relative; height: 7mm; width: 130mm; display: flex; justify-content: center; }
.fline { position: absolute; left: 50%; top: 0; bottom: 1.6mm; border-left: 1.6px solid #50677f; }
.farrow::after { content: ""; position: absolute; left: calc(50% - 1.6mm); bottom: 0; border-left: 1.7mm solid transparent; border-right: 1.7mm solid transparent; border-top: 2mm solid #50677f; margin-left: 0.1mm; }
.flab { position: absolute; left: calc(50% + 3mm); top: 1.2mm; color: #2c4a6b; font-size: 7.8pt; font-style: italic; white-space: nowrap; }
.fback { color: #2c4a6b; font-size: 7.8pt; font-style: italic; margin-top: 1mm; }
.hflowbox { margin: 2mm 0 3mm; font-size: 8.4pt; break-inside: avoid; }
.hrow { display: flex; align-items: center; margin: 1.5mm 0; }
.hrow .fbox { min-width: 0; padding: 1mm 2mm; }
.harrow { position: relative; flex: 0 0 auto; min-width: 12mm; height: 7mm; display: flex; flex-direction: column; justify-content: center; align-items: center; padding: 0 1mm; }
.hline { display: block; width: 100%; border-top: 1.6px solid #50677f; position: relative; }
.hline::after { content: ""; position: absolute; right: -0.5mm; top: -1.85mm; border-top: 1.7mm solid transparent; border-bottom: 1.7mm solid transparent; border-left: 2mm solid #50677f; }
.pinbox { display: flex; align-items: stretch; margin: 3mm 0 4mm; font-size: 7.6pt; break-inside: avoid; }
.pcol { flex: 1 1 0; display: flex; flex-direction: column; justify-content: center; gap: 1.6mm; }
.pblock { flex: 0 0 34mm; background: #1f4e8c; color: #fff; border-radius: 5px; display: flex; flex-direction: column; justify-content: center; align-items: center; text-align: center; padding: 2mm; }
.pname { font-weight: 700; font-size: 10pt; }
.psub { font-size: 7.4pt; color: #dbe7f6; margin-top: 1mm; }
.pin { display: flex; align-items: center; }
.pin.l .ptext { text-align: right; }
.ptext { flex: 1 1 auto; border: 1px solid #c9d6e4; background: #f6f9fc; border-radius: 3px; padding: 0.6mm 1.6mm; }
.parr { flex: 0 0 7mm; padding: 0 0.6mm; }
.psig { font-family: Menlo, monospace; font-weight: 600; color: #1d2b3a; font-size: 7.2pt; }
.ppeer { color: #a35a00; font-size: 6.9pt; font-weight: 600; }
.pdesc { color: #4f6072; font-size: 6.9pt; }
.hlab { font-size: 7.4pt; color: #2c4a6b; font-style: italic; white-space: nowrap; margin-bottom: 0.4mm; }
"""
