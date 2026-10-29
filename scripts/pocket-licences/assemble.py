import json, sys, re, collections, hashlib
r = json.load(open(sys.argv[1]))["results"]
out = sys.argv[2]

def spdx_ids(expr):
    if not expr: return set()
    return set(re.findall(r"[A-Za-z0-9.\-]+(?:-or-later|-only)?", expr.replace("/", " OR "))) - {"OR", "AND", "WITH"}

# Canonical full texts, taken verbatim from crates that ship them (searched by licence id).
def find_text(pred):
    for x in r:
        for name, text in x["files"].items():
            if pred(name.upper(), text): return text, f"{x['name']} {x['version']}/{name}"
    return None, None
canon = {
    "Apache-2.0": find_text(lambda n, t: "APACHE" in n and "Apache License" in t and "Version 2.0" in t and "END OF TERMS" in t),
    "MPL-2.0": find_text(lambda n, t: "Mozilla Public License Version 2.0" in t),
    "Zlib": find_text(lambda n, t: "ZLIB" in n and "This software is provided 'as-is'" in t),
    "BSL-1.0": find_text(lambda n, t: "Boost Software License - Version 1.0" in t),
}
missing_canon = [k for k, v in canon.items() if not v[0]]
mit_permission = ("Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated "
    "documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the "
    "rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit "
    "persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice "
    "and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS "
    "PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF "
    "MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT "
    "HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, "
    "ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.")

def src(x):
    if x["name"] == "ptts": return x["repo"]
    return f"https://crates.io/crates/{x['name']}/{x['version']}"

L = []
L.append("THIRD-PARTY LICENCES — Pocket TTS 3.3.0 (Contents/Helpers/pocket-tts)\n")
L.append("The Pocket TTS program bundled with OpenWhisperer is Kyutai Labs' release v4.0.1 of kyutai-labs/pocket-tts\n"
         "(MIT; its own licence is LICENSE-pocket-tts.txt beside this file), used unmodified. It is built from the Rust\n"
         "crates below. This list was generated from that release's rust/Cargo.lock: every crate was fetched from\n"
         "crates.io (the one git dependency from GitHub at its pinned revision), checked against Cargo.lock's sha256,\n"
         "and its licence files copied verbatim. Cargo.lock covers every platform and feature, so this is a superset of\n"
         "what the macOS arm64 program actually contains.\n\n"
         "Where a crate is offered under a choice of licences (\"A OR B\"), OpenWhisperer distributes it under the\n"
         "permissive option among them (MIT, Apache-2.0, Zlib, ISC or BSD), never under LGPL.\n\n"
         "MPL-2.0 crates are distributed in executable form only, unmodified. As MPL-2.0 section 3.2 requires, their\n"
         "Source Code Form is available at the crates.io address listed for each one below.\n")
L.append("\n== CRATES ==\n")
for x in r:
    L.append(f"{x['name']} {x['version']} — {x['license'] or 'see its licence files'} — {src(x)}")

L.append("\n\n== LICENCE TEXTS SHIPPED BY THE CRATES (verbatim; identical texts listed once) ==\n")
groups = collections.OrderedDict()
for x in r:
    for name, text in sorted(x["files"].items()):
        key = hashlib.sha256(text.strip().encode()).hexdigest()
        groups.setdefault(key, [text, []])[1].append(f"{x['name']} {x['version']} ({name})")
for text, who in groups.values():
    L.append("-" * 78)
    L.append("Applies to: " + "; ".join(who))
    L.append("-" * 78)
    L.append(text.strip() + "\n")

nofile = [x for x in r if not x["files"]]
L.append("\n== CRATES THAT SHIP NO LICENCE FILE ==\n")
L.append("These crates declare their licence in Cargo.toml but include no licence file. Their copyright holders are the\n"
         "authors they declare; the licence texts are reproduced in full below (MIT) or above, verbatim from another\n"
         "crate (Apache-2.0, MPL-2.0, Zlib, BSL-1.0 — see the canonical copies named at the end).\n")
for x in nofile:
    authors = ", ".join(x["authors"]) if x["authors"] else f"the {x['name']} authors"
    L.append(f"{x['name']} {x['version']} — {x['license']} — {src(x)}\n  Copyright (c) {authors}")
L.append("\nMIT licence, for the crates above that choose or declare MIT, with the copyright line given for each:\n")
L.append(mit_permission + "\n")
L.append("\nCanonical full texts used for the crates above (found verbatim in this document):")
for k, (text, where) in canon.items():
    L.append(f"  {k}: the copy from {where}")
open(out, "w").write("\n".join(L) + "\n")

needed = set().union(*(spdx_ids(x["license"]) for x in nofile))
print("licences needed by file-less crates:", sorted(needed))
print("canonical texts missing:", missing_canon)
print("unique texts:", len(groups), "| file-less crates:", len(nofile), "| bytes:", sum(len(l) + 1 for l in L))
