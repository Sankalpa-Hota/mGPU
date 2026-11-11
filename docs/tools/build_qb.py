"""Build the Question Bank PDF and the Answer Book PDF from sections/*.md.

Markdown extensions:
  ?? <question>            -> styled Q block, following text = answer (until next ?? / heading / ---)
  ```wave ... ```          -> SVG timing diagram  (signal | chars | labels)
  ```mermaid ... ```       -> Mermaid diagram (FSMs)
"""
import pathlib, re, html, markdown, sys
from pygments.formatters import HtmlFormatter

ROOT = pathlib.Path(__file__).parent
S = ROOT / "sections"
FILES = ["s1_constraints.md", "s2_assertions.md", "s3_uvm.md", "s4_comparch.md", "s5_coding.md"]

# ---------------------------------------------------------------- timing diagrams
CELL, NAMEW, ROWH, SIGH = 30, 96, 30, 16

def wave_svg(src):
    rows = []
    for line in src.strip("\n").split("\n"):
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split("|")]
        name, w = parts[0], parts[1].replace(" ", "")
        labels = parts[2].split() if len(parts) > 2 and parts[2] else []
        rows.append((name, w, labels))
    ncyc = max(len(w) for _, w, _ in rows)
    W = NAMEW + ncyc * CELL + 10
    H = 22 + len(rows) * ROWH + 4
    o = [f'<svg class="wave" xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">']
    o.append('<defs><pattern id="hx" width="5" height="5" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
             '<line x1="0" y1="0" x2="0" y2="5" stroke="#b9c2cf" stroke-width="2"/></pattern></defs>')
    for c in range(ncyc + 1):
        x = NAMEW + c * CELL
        o.append(f'<line x1="{x}" y1="14" x2="{x}" y2="{H-2}" stroke="#e3e8ef" stroke-width="1"/>')
        if c < ncyc:
            o.append(f'<text x="{x + CELL/2}" y="11" font-size="9" fill="#8a94a3" text-anchor="middle">{c}</text>')
    for r, (name, w, labels) in enumerate(rows):
        top = 22 + r * ROWH
        yh, yl = top + 3, top + 3 + SIGH
        ym = (yh + yl) / 2
        o.append(f'<text x="4" y="{ym + 4}" font-size="11" fill="#1d2330" font-family="Menlo,monospace">{html.escape(name)}</text>')
        # segments
        segs = []
        for i, ch in enumerate(w):
            if ch == "." and segs:
                segs[-1][1] = i + 1
            else:
                segs.append([i, i + 1, ch])
        if any(s[2] == "p" for s in segs) or w.startswith("p"):
            pts = []
            for c in range(len(w)):
                x0 = NAMEW + c * CELL
                pts += [(x0, yl), (x0, yh), (x0 + CELL / 2, yh), (x0 + CELL / 2, yl), (x0 + CELL, yl)]
            o.append('<polyline fill="none" stroke="#1f4e8c" stroke-width="1.4" points="' +
                     " ".join(f"{x},{y}" for x, y in pts) + '"/>')
            continue
        li = 0
        prev_level = None
        for s0, s1, ch in segs:
            x0, x1 = NAMEW + s0 * CELL, NAMEW + s1 * CELL
            if ch in "01hl":
                y = yh if ch in "1h" else yl
                if prev_level is not None and prev_level != y:
                    o.append(f'<line x1="{x0}" y1="{yh}" x2="{x0}" y2="{yl}" stroke="#1d2330" stroke-width="1.4"/>')
                o.append(f'<line x1="{x0}" y1="{y}" x2="{x1}" y2="{y}" stroke="#1d2330" stroke-width="1.4"/>')
                prev_level = y
            elif ch in "x=":
                d = 3
                poly = f"{x0},{ym} {x0+d},{yh} {x1-d},{yh} {x1},{ym} {x1-d},{yl} {x0+d},{yl}"
                fill = "url(#hx)" if ch == "x" else "#eef4fb"
                o.append(f'<polygon points="{poly}" fill="{fill}" stroke="#1d2330" stroke-width="1"/>')
                if ch == "=" and li < len(labels):
                    o.append(f'<text x="{(x0+x1)/2}" y="{ym+3.5}" font-size="9.5" text-anchor="middle" '
                             f'font-family="Menlo,monospace" fill="#14233a">{html.escape(labels[li])}</text>')
                    li += 1
                prev_level = None
            elif ch == "z":
                o.append(f'<line x1="{x0}" y1="{ym}" x2="{x1}" y2="{ym}" stroke="#4b7bd1" stroke-width="1.4"/>')
                prev_level = None
    o.append("</svg>")
    return "".join(o)

def preprocess(text):
    def wave(m):
        return f'\n<div class="wavebox">{wave_svg(m.group(1))}</div>\n'
    text = re.sub(r"```wave\n(.*?)```", wave, text, flags=re.S)
    def merm(m):
        body = "\n".join(l for l in m.group(1).split("\n") if l.strip())
        return f'\n<div class="mermaidbox"><pre class="mermaid">\n{html.escape(body)}\n</pre></div>\n'
    text = re.sub(r"```mermaid\n(.*?)```", merm, text, flags=re.S)
    return text

def qa_blocks(text):
    out, in_fence, open_qa = [], False, False
    def close():
        out.append("\n</div>\n\n</div>\n")
    for line in text.split("\n"):
        if line.startswith("```"):
            in_fence = not in_fence
        if not in_fence and line.startswith("?? "):
            if open_qa: close()
            out.append(f'\n<div class="qa" markdown="1">\n\n<div class="q" markdown="1">\n\n{line[3:]}\n\n</div>\n\n<div class="a" markdown="1">\n')
            open_qa = True
            continue
        if open_qa and not in_fence and (line.startswith("#") or line.strip() == "---"):
            close(); open_qa = False
        out.append(line)
    if open_qa: close()
    return "\n".join(out)

CSS = """
@page { size: Letter; margin: 15mm 14mm 15mm 14mm;
  @bottom-right { content: counter(page); font: 8pt -apple-system, 'Helvetica Neue', sans-serif; color: #8a8f98; }
  @bottom-left  { content: "%FOOT%"; font: 8pt -apple-system, 'Helvetica Neue', sans-serif; color: #8a8f98; } }
@page :first { @bottom-right { content: none; } @bottom-left { content: none; } }
:root { --ink:#1d2330; --muted:#5b6474; --accent:#1f4e8c; --rule:#dfe3ea; --code-bg:#f6f8fb; --tint:#eef4fb; --qbg:#f3f6fb; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { font-family: -apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 10.1pt; line-height: 1.5; color: var(--ink); margin: 0; }
h1 { font-size: 21pt; color: var(--accent); margin: 0 0 4mm; padding-bottom: 2mm; border-bottom: 2px solid var(--accent); }
h2 { font-size: 13.5pt; margin: 8mm 0 2mm; break-after: avoid; color: #14233a; }
h3 { font-size: 11pt; color: var(--accent); margin: 5mm 0 1.5mm; break-after: avoid; }
p { margin: 0 0 2.3mm; }  ul, ol { margin: 0 0 2.3mm; padding-left: 5.5mm; }  li { margin: .5mm 0; }
a { color: var(--accent); text-decoration: none; }
.chapter { break-before: page; }
code { font-family: 'SF Mono', Menlo, Consolas, monospace; font-size: 8.6pt; background: var(--code-bg); padding: .2mm 1mm; border-radius: 2px; }
.hl { background: var(--code-bg); border-left: 3px solid #b8c7dd; border-radius: 3px; margin: 1.5mm 0 3.5mm; padding: 2.2mm 3mm; break-inside: avoid; }
.hl.long { break-inside: auto; }
.hl pre { margin: 0; font-family: 'SF Mono', Menlo, Consolas, monospace; font-size: 8.2pt; line-height: 1.42; white-space: pre-wrap; word-break: break-word; }
.hl pre code, pre code { background: none; padding: 0; font-size: inherit; }
pre { background: var(--code-bg); padding: 2.2mm 3mm; font-size: 8.2pt; white-space: pre-wrap; }
table { border-collapse: collapse; width: 100%; margin: 1.5mm 0 4mm; font-size: 8.9pt; }
th { text-align: left; background: var(--tint); color: #17304f; font-weight: 600; border-bottom: 1.5px solid #b8c7dd; padding: 1.3mm 2mm; }
td { border-bottom: 1px solid var(--rule); padding: 1.2mm 2mm; vertical-align: top; }
tr { break-inside: avoid; }
blockquote { margin: 2mm 0 3.5mm; padding: 2.5mm 4mm; background: var(--tint); border-left: 3px solid var(--accent); border-radius: 3px; break-inside: avoid; }
blockquote p:last-child { margin-bottom: 0; }
.qa { margin: 4mm 0 4mm; }
.q { background: var(--qbg); border-left: 3px solid var(--accent); border-radius: 3px; padding: 1.8mm 3mm 1.8mm 9mm; position: relative; font-weight: 600; color: #14233a; break-after: avoid; break-inside: avoid; }
.q::before { content: "Q"; position: absolute; left: 2.6mm; top: 1.7mm; font-weight: 800; color: var(--accent); }
.q p { margin: 0; }
.a { padding: 1.8mm 0 0 9mm; position: relative; }
.a::before { content: "A"; position: absolute; left: 2.9mm; top: 1.7mm; font-weight: 800; color: #6b8f71; }
.wavebox { margin: 2mm 0 4mm; padding: 2mm 3mm; border: 1px solid var(--rule); border-radius: 4px; break-inside: avoid; overflow: hidden; }
.wave { max-width: 100%; height: auto; }
.mermaidbox { margin: 2mm 0 4mm; padding: 2mm; border: 1px solid var(--rule); border-radius: 4px; text-align: center; break-inside: avoid; }
.mermaidbox pre.mermaid { background: none; margin: 0; }
.cover { padding-top: 45mm; }
.cover .kicker { font-size: 9pt; letter-spacing: 1.6px; text-transform: uppercase; color: var(--muted); }
.cover h1 { font-size: 29pt; border: none; margin: 3mm 0 3mm; }
.cover .sub { font-size: 11.5pt; color: var(--muted); margin-bottom: 8mm; max-width: 160mm; }
.cover .box { background: var(--tint); border-radius: 4px; padding: 4mm 5mm; font-size: 9.6pt; max-width: 165mm; }
.toc li { margin-bottom: 2mm; }
.toc .subs { font-size: 8.4pt; color: var(--muted); }
/* question bank */
.qb h2 { font-size: 12pt; margin-top: 6mm; }
.qb ol { padding-left: 0; list-style: none; }
.qb li { margin: 0 0 2mm; padding: 1.4mm 2.5mm; border-bottom: 1px solid var(--rule); break-inside: avoid; }
.qb .id { display: inline-block; min-width: 13mm; font-weight: 700; color: var(--accent); }
"""

def page(title, foot, cover, body, css_code):
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>
<style>{CSS.replace('%FOOT%', foot)}{css_code}
.hl .c1, .hl .cm, .hl .c {{ color: #5f7f5f; font-style: normal; }}</style></head><body>
{cover}{body}
<script src="https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"></script>
<script>mermaid.initialize({{startOnLoad:true, theme:'neutral', securityLevel:'loose',
  flowchart:{{htmlLabels:false}}, state:{{useMaxWidth:true}}, themeVariables:{{fontSize:'13px'}}}});</script>
</body></html>"""

def mark_long(h):
    def f(m):
        blk = m.group(0)
        return blk.replace('<div class="hl">', '<div class="hl long">', 1) if blk.count("\n") > 22 else blk
    return re.sub(r'<div class="hl">.*?</pre></div>', f, h, flags=re.S)

def main():
    md = markdown.Markdown(extensions=["fenced_code", "codehilite", "tables", "md_in_html", "attr_list", "sane_lists"],
                           extension_configs={"codehilite": {"guess_lang": False, "css_class": "hl"}})
    css_code = HtmlFormatter(style="friendly").get_style_defs(".hl")
    chapters, toc, qb = [], [], []
    for i, fn in enumerate(FILES):
        text = (S / fn).read_text()
        title = re.search(r"^# (.+)$", text, re.M).group(1)
        anchor = f"c{i}"
        subs = re.findall(r"^## (.+)$", text, re.M)
        toc.append((anchor, title, subs))
        # question bank extraction
        qb.append(f"<h1>{html.escape(title)}</h1>")
        cur = []
        in_fence = False
        for line in text.split("\n"):
            if line.startswith("```"): in_fence = not in_fence
            if in_fence: continue
            if line.startswith("## "):
                if cur: qb.append("<ol>" + "".join(cur) + "</ol>"); cur = []
                qb.append(f"<h2>{html.escape(line[3:])}</h2>")
            elif line.startswith("?? "):
                q = line[3:]
                m = re.match(r"\*\*([A-Z]+\d+[a-z]?)\*\*\s*[·.\-—]?\s*(.*)", q)
                qid, qtxt = (m.group(1), m.group(2)) if m else ("", q)
                md.reset()
                qhtml = md.convert(qtxt)
                qhtml = re.sub(r"^<p>|</p>$", "", qhtml.strip())
                cur.append(f'<li><span class="id">{qid}</span>{qhtml}</li>')
        if cur: qb.append("<ol>" + "".join(cur) + "</ol>")
        # answer book
        text = re.sub(r"^# (.+)$", lambda m: f"# {m.group(1)} {{#{anchor}}}", text, count=1, flags=re.M)
        md.reset()
        chapters.append(f'<section class="chapter">{md.convert(qa_blocks(preprocess(text)))}</section>')

    toc_html = "<div class='chapter toc'><h1>Contents</h1><ol>" + "".join(
        f'<li><a href="#{a}"><b>{t}</b></a><div class="subs">{" · ".join(html.escape(s) for s in subs)}</div></li>'
        for a, t, subs in toc) + "</ol></div>"
    nq = sum(h.count("<li>") for h in qb)

    cover_a = f"""<div class="cover"><div class="kicker">DV interview preparation · answer book</div>
<h1>DV Interview Question Bank — Answers</h1>
<div class="sub">Every question from the collected SoC-DV / GPU-DV interview logs, answered in depth: constraints · assertions & coverage · UVM & methodology · computer architecture & digital design · coding (RTL/FSM, handshakes, SV, C/C++, Python, DSA)</div>
<div class="box"><b>How to read:</b> each question carries the same ID as the Question Bank PDF (C = constraints, A = assertions/coverage, U = UVM, CA = computer architecture/digital design, K = coding). Practice from the Question Bank first, then check here. Code comments starting with <code>// why:</code> explain the reason behind a line. RTL/FSM answers include a state diagram, a state table and a cycle-by-cycle timing diagram.<br><br>
<b>Candidate:</b> Sankalpa Hota — prepared for Qualcomm GPU / SoC DV interviews.</div></div>"""
    html_a = page("DV Interview Answers", "DV Interview Question Bank · Answers", cover_a, toc_html + "".join(chapters), css_code)
    (ROOT / "answers.html").write_text(mark_long(html_a))

    cover_q = f"""<div class="cover"><div class="kicker">DV interview preparation · practice sheet</div>
<h1>DV Interview Question Bank</h1>
<div class="sub">{nq} questions collected from SoC-DV / GPU-DV interview logs, de-duplicated and grouped. Answers (same IDs) are in the companion Answer Book.</div>
<div class="box"><b>How to use:</b> answer each question out loud or on paper with a timer, then check the Answer Book. Questions marked <i>(truncated in log)</i> were cut off in the original notes; the Answer Book answers the most likely intent.</div></div>"""
    html_q = page("DV Interview Question Bank", "DV Interview Question Bank", cover_q,
                  "<div class='chapter qb'>" + "".join(qb) + "</div>", css_code)
    (ROOT / "questions.html").write_text(html_q)
    print("questions:", nq)

if __name__ == "__main__":
    main()
