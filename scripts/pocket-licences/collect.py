"""Collect licence notices for every crate in pocket-tts's Cargo.lock (v4.0.1).
Each .crate is fetched from static.crates.io, verified against Cargo.lock's sha256 checksum, and
read IN MEMORY: only top-level licence-like files and Cargo.toml's licence fields are taken; nothing
is extracted to disk. The git dependency (ptts from xn-ptts) is read from GitHub at its pinned rev."""
import sys, io, re, json, hashlib, tarfile, tomllib, urllib.request, concurrent.futures, base64, subprocess
lock_path, out_path = sys.argv[1], sys.argv[2]
lock = tomllib.load(open(lock_path, "rb"))
NAMES = re.compile(r"(?i)^(licen[cs]e|copying|notice|copyright|unlicense|authors)([-_.].*)?$")

def from_crate(p):
    url = f"https://static.crates.io/crates/{p['name']}/{p['name']}-{p['version']}.crate"
    # curl, not urllib: it verifies TLS against the system trust store (python.org's Python ships
    # without a CA bundle here). The checksum against Cargo.lock below is the real pin anyway.
    data = subprocess.run(["/usr/bin/curl", "-sSfL", "--max-time", "120", "--max-filesize", "52428800", url],
                          capture_output=True, check=True).stdout
    if hashlib.sha256(data).hexdigest() != p["checksum"]:
        raise RuntimeError(f"checksum mismatch for {p['name']} {p['version']}")
    files, license_expr, authors, repo = {}, None, [], None
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        for m in tf.getmembers():
            if not m.isfile():
                continue
            parts = m.name.split("/")
            if len(parts) != 2:
                continue
            if NAMES.match(parts[1]) and m.size < 512_000:
                files[parts[1]] = tf.extractfile(m).read().decode("utf-8", "replace")
            elif parts[1] == "Cargo.toml":
                pk = tomllib.loads(tf.extractfile(m).read().decode("utf-8", "replace")).get("package", {})
                license_expr = pk.get("license") or (f"see {pk['license-file']}" if pk.get("license-file") else None)
                authors, repo = pk.get("authors", []), pk.get("repository")
    return dict(name=p["name"], version=p["version"], license=license_expr, authors=authors, repo=repo, files=files)

def from_git(p):
    repo, rev = re.match(r"git\+https://github.com/([^?#]+)\?rev=([0-9a-f]+)", p["source"]).groups()
    gh = "/Users/peripan/dev/gh_CLI/bin/gh"
    tree = json.loads(subprocess.run([gh, "api", f"repos/{repo}/git/trees/{rev}?recursive=1"], capture_output=True, text=True, check=True).stdout)
    files = {}
    for t in tree["tree"]:
        name = t["path"].split("/")[-1]
        if t["type"] == "blob" and NAMES.match(name) and t["path"].count("/") <= 1:
            blob = json.loads(subprocess.run([gh, "api", f"repos/{repo}/git/blobs/{t['sha']}"], capture_output=True, text=True, check=True).stdout)
            files[t["path"]] = base64.b64decode(blob["content"]).decode("utf-8", "replace")
    return dict(name=p["name"], version=p["version"], license=None, authors=[], repo=f"https://github.com/{repo} @ {rev}", files=files)

pkgs = [p for p in lock["package"] if p.get("source")]
results, failures = [], []
with concurrent.futures.ThreadPoolExecutor(8) as ex:
    futs = {ex.submit(from_git if p["source"].startswith("git+") else from_crate, p): p for p in pkgs}
    for f in concurrent.futures.as_completed(futs):
        p = futs[f]
        try:
            results.append(f.result())
        except Exception as e:
            failures.append((p["name"], p["version"], str(e)))
results.sort(key=lambda r: (r["name"], r["version"]))
json.dump(dict(results=results, failures=failures), open(out_path, "w"), indent=1)
print(f"collected {len(results)} of {len(pkgs)}; failures: {len(failures)}")
for f in failures[:10]: print("  FAIL", f)
