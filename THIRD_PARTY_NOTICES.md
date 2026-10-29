# Third-party notices

OpenWhisperer itself is MIT (see `LICENSE`). It ships, links or downloads the following. A copy of
this file is inside the app (`OpenWhisperer.app/Contents/Resources/THIRD_PARTY_NOTICES.md`).

Material under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/) is used **unmodified**: the
Pocket TTS model and its voice states as Kyutai publishes them, and Heart as Estia exported it. The
audio OpenWhisperer produces from them is speech synthesized on your Mac.

## Shipped inside the app

| Component | Licence | How it is used |
|---|---|---|
| Pocket TTS 3.3.0 (Kyutai Labs, [`kyutai-labs/pocket-tts`](https://github.com/kyutai-labs/pocket-tts): the macOS arm64 program of its GitHub release v4.0.1) | MIT — its licence file ships beside it (`Contents/Resources/pocket/LICENSE-pocket-tts.txt`), with the licence notices of the Rust crates it is built from (`Contents/Resources/pocket/THIRD_PARTY_LICENSES-pocket-tts.txt`, generated from the release's `rust/Cargo.lock`) | `Contents/Helpers/pocket-tts`. Pinned by the release tarball's and the program's sha256 at build time (`app/build-dmg.sh`, held equal to `PocketTTS` in the Kit by `HookTests`), then signed with the app; used unmodified. Speaks English, one sentence per run, on the CPU, under macOS's sandbox (no network, no other program, no file written). The program is built from Rust crates, most MIT or Apache-2.0; per Estia's audit of the same build, 18 are MPL-2.0 (colored 3.1.1, option-ext 0.2.0, and symphonia 0.5.5 with its parts), their source on crates.io. |
| The voice Heart (`app/Resources/pocket/heart.safetensors`, 8,652,024 bytes) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) (Kyutai) and Apache-2.0 ([Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), hexgrad) | A Pocket TTS voice state for the 100M English model: Kokoro-82M's voice af_heart, cloned once onto Pocket TTS with Kyutai's voice-cloning model (`kyutai/pocket-tts` at db04f0e6) and written out by Pocket TTS 3.3.0's `export-voice`. Made for Estia (local-assistant) and used here byte for byte. Kyutai's cloning model is not part of OpenWhisperer, which never downloads or runs it. Kokoro does not document what audio af_heart was trained on. Kyutai's prohibited uses (below) apply. Credit: Kyutai, Pocket TTS; hexgrad, Kokoro-82M. |
| jq 1.7.1 | MIT | `Contents/Resources/jq`, used by the agent hooks to read and write JSON. |

## Swift packages (compiled in)

| Component | Licence |
|---|---|
| WhisperKit 1.1.1 (argmaxinc) | MIT (its NOTICES list swift-transformers, Apache-2.0) |
| FluidAudio 0.15.8 (FluidInference) | Apache-2.0 (with its own third-party licence file) |
| swift-argument-parser | Apache-2.0 |

## Downloaded at runtime

None of these are in this repository.

| Component | Licence | When |
|---|---|---|
| Whisper large-v3 turbo, CoreML build (`argmaxinc/whisperkit-coreml`) | MIT | First launch (~1.5 GB). Check the model card. |
| Whisper large-v3, CoreML build (`openai_whisper-large-v3_947MB`) | MIT | Only if you turn on Translate to English (~948 MB). |
| Whisper large-v3 tokenizer files (`openai/whisper-large-v3`) | Apache-2.0 | With the model. |
| Pocket TTS English model, 100M parameters ([`kyutai/pocket-tts-without-voice-cloning`](https://huggingface.co/kyutai/pocket-tts-without-voice-cloning): `languages/english`, its weights and tokenizer, each at a pinned commit) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) (Kyutai) | First launch (~220 MB), checked by sha256. Without the encoder these weights cannot clone a voice. Credit: Kyutai, Pocket TTS. |
| The Pocket voices Jane, Eve, Vera and Michael (`languages/english/embeddings/<name>.safetensors` in the repository above, made from VCTK speakers p339, p361, p229 and p360, [`kyutai/tts-voices`](https://huggingface.co/kyutai/tts-voices)) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | The first time you choose one (~6–7 MB each), checked by sha256. From the VCTK corpus (CSTR VCTK Corpus). Credit: VCTK corpus, University of Edinburgh. |
| The Pocket voice Alba (`languages/english/embeddings/alba.safetensors`, from a recording voice-acted by Alba MacKenna, [`kyutai/tts-voices`](https://huggingface.co/kyutai/tts-voices)) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | The first time you choose it (~6 MB), checked by sha256. Credit: Alba MacKenna. |
| Kokoro-82M (CoreML, `FluidInference/kokoro-82m-coreml`), its voices (`onnx-community/Kokoro-82M-v1.0-ONNX`) and the Misaki lexicon | See the model cards (Apache-2.0 / MIT as far as known) | First launch: Kokoro speaks any line Pocket can't, and its own voices when you choose one. Confirm the licence on the model cards before you redistribute the models. |
| Supertonic-3 (Supertone Inc.), the CoreML build `FluidInference/supertonic-3-coreml` and its voice styles | OpenRAIL-M (the BigScience Open RAIL-M License of 18 August 2022), with its use-based restrictions (Attachment A) | The first time you choose a voice in a language Kokoro can't speak. The licence is the one on the `Supertone/supertonic-3` model card and in its `LICENSE` file; the FluidInference build's card says it inherits it. Read the licence and its restrictions before you use or redistribute the model. |

## Kyutai's prohibited uses (Pocket TTS models and voices, Heart included)

"Use of our model must comply with all applicable laws and regulations and must not result in, involve, or facilitate any illegal, harmful, deceptive, fraudulent, or unauthorized activity. Prohibited uses include, without limitation, voice impersonation or cloning without explicit and lawful consent; misinformation, disinformation, or deception (including fake news, fraudulent calls, or presenting generated content as genuine recordings of real people or events); and the generation of unlawful, harmful, libelous, abusive, harassing, discriminatory, hateful, or privacy-invasive content."
