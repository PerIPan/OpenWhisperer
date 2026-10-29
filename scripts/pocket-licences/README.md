# Pocket TTS crate licences

`app/Resources/pocket/THIRD_PARTY_LICENSES-pocket-tts.txt` is **generated** — regenerate it whenever the
bundled Pocket TTS release changes (`PocketTTS.releaseURL` and `build-dmg.sh`'s pins), never edit it by hand.

```bash
gh api 'repos/kyutai-labs/pocket-tts/contents/rust/Cargo.lock?ref=<tag>' -q .content | base64 -d > /tmp/Cargo.lock
python3 -I scripts/pocket-licences/collect.py /tmp/Cargo.lock /tmp/licences.json     # fetches + checksum-verifies every crate
python3 -I scripts/pocket-licences/assemble.py /tmp/licences.json app/Resources/pocket/THIRD_PARTY_LICENSES-pocket-tts.txt
```

`collect.py` fetches each crate with `curl` (system trust store), checks it against Cargo.lock's sha256 and reads only
its top-level licence files, in memory — nothing from a crate is extracted to disk. `assemble.py` dedupes identical
texts, lists every crate with its source (the MPL-2.0 source-availability notice), and gives the crates that ship no
licence file their declared licence and authors. It needs `gh` for the one git dependency.
