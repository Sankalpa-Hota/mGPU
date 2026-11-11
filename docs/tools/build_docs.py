"""Builds the mGPU documentation PDFs from docs/src/*.md.

  one PDF per source file   -> docs/modules/<name>.pdf
  everything in one PDF      -> docs/mGPU_Design_and_Verification_Guide.pdf

Run from anywhere:
  uv run --no-project --with markdown --with pygments python docs/tools/build_docs.py [name-filter ...]

Figure fences: ```wave``` (timing diagram), ```tree```, ```flow```, ```hflow``` (box diagrams).
"""
import pathlib, re, sys, html, subprocess
import markdown
from pygments.formatters import HtmlFormatter

TOOLS = pathlib.Path(__file__).resolve().parent
DOCS = TOOLS.parent
sys.path.insert(0, str(TOOLS))
import build_qb as B, figs

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CSS = figs.CSS + """
.chapter { break-before: page; }
.toc { break-after: page; }
.hl pre, pre { white-space: pre-wrap !important; word-break: break-word; font-family: Menlo, Monaco, monospace !important; font-size: 7.9pt !important; }
.hl, blockquote { break-inside: auto !important; }
body { font-size: 9.8pt; line-height: 1.45; }
h2 { break-after: avoid; } h3 { break-after: avoid; margin-top: 4mm; }
.why { border-left: 3px solid #1f4e8c; background: #f4f8fd; padding: 1.5mm 3mm; margin: 2mm 0; break-inside: avoid; }
.mtoc { list-style: none; padding-left: 0; }
.mtoc li { margin: 1.2mm 0; }
.mtoc a { text-decoration: none; color: #1f4e8c; }
.wavebox svg { max-width: 100%; height: auto; }
"""


def convert(text):
    md = markdown.Markdown(extensions=["fenced_code", "codehilite", "tables", "md_in_html", "attr_list", "sane_lists"],
                           extension_configs={"codehilite": {"guess_lang": False, "css_class": "hl"}})
    text = figs.preprocess(B.preprocess(text))
    return md.convert(text)


def to_pdf(title, sub, kicker, sections, out_pdf, toc=True):
    css = HtmlFormatter(style="friendly").get_style_defs(".hl") + CSS
    body, items = [], []
    for k, (t, raw) in enumerate(sections):
        anchor = f"s{k}"
        raw = re.sub(r"^# (.+)$", lambda m: f"# {m.group(1)} {{#{anchor}}}", raw, count=1, flags=re.M)
        items.append((anchor, t))
        body.append(f'<section class="chapter">{convert(raw)}</section>')
    toc_html = ""
    if toc and len(sections) > 1:
        toc_html = "<div class='chapter toc'><h1>Contents</h1><ul class='mtoc'>" + "".join(
            f'<li><a href="#{a}"><b>{html.escape(t)}</b></a></li>' for a, t in items) + "</ul></div>"
    cover = f'<div class="cover"><div class="kicker">{kicker}</div><h1>{title}</h1><div class="sub">{sub}</div></div>'
    h = B.mark_long(B.page(title, title, cover, toc_html + "".join(body), css))
    hp = out_pdf.with_suffix(".html")
    hp.write_text(h)
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer", "--generate-pdf-document-outline",
                    "--virtual-time-budget=15000", f"--print-to-pdf={out_pdf}", f"file://{hp}"], capture_output=True)
    hp.unlink()


def main():
    srcs = sorted((DOCS / "src").glob("*.md"))
    only_modules = "--modules-only" in sys.argv
    only_combined = "--combined-only" in sys.argv
    filt = [a for a in sys.argv[1:] if not a.startswith("--")]
    secs = []
    for f in srcs:
        raw = f.read_text()
        title = re.search(r"^# (.+)$", raw, re.M).group(1)
        secs.append((f, title, raw))
    (DOCS / "modules").mkdir(exist_ok=True)
    for f, title, raw in secs:
        if only_combined:
            break
        if filt and not any(x in f.name for x in filt):
            continue
        to_pdf(title, "Architecture, RTL decisions and verification decisions", "mGPU · block document",
               [(title, raw)], DOCS / "modules" / (f.stem + ".pdf"))
        print("built", f.stem + ".pdf")
    if only_modules:
        return
    to_pdf("mGPU Design and Verification Guide",
           "A small but complete GPU: every block's architecture, RTL choices, testbench and the reason behind each verification decision",
           "mGPU · full guide", [(t, r) for _, t, r in secs], DOCS / "mGPU_Design_and_Verification_Guide.pdf")
    print("built mGPU_Design_and_Verification_Guide.pdf")
    log = DOCS / "issue_log" / "mGPU_RTL_Issue_Log.md"
    if log.exists():
        raw = log.read_text().replace("%%MORE%%", "")
        to_pdf("mGPU RTL Issue Log", "Every real RTL issue found during verification: cause, fix, how it was caught, and how to find such bugs",
               "mGPU · issue log", [("mGPU RTL issue log", raw)], DOCS / "mGPU_RTL_Issue_Log.pdf")
        print("built mGPU_RTL_Issue_Log.pdf")


if __name__ == "__main__":
    main()
