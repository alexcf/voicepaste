# VoicePaste

A tiny macOS menu-bar app for dictating into any app — handy for apps with no voice input.

Press **⌘⇧Space**, talk, and VoicePaste records you, transcribes it, copies the text to the clipboard, and pastes it into the app you were using.

- **Tap ⌘⇧Space** — start recording. It stops by itself when you stop talking (or tap again to stop early).
- **Hold ⌘⇧Space** — push-to-talk; release to finish.
- Menu-bar mic turns **red** while recording, **orange** while transcribing.

## Transcription engines

Pick one in **Settings…** (menu-bar mic → Settings):

### Apple (built-in) — default
macOS speech recognition, on-device where your language supports it. No account, key or download.

### API (any OpenAI-compatible `/v1/audio/transcriptions` endpoint)
Presets in Settings fill in the URL and model:

| Preset | URL | Model | Key |
|---|---|---|---|
| OpenAI | `https://api.openai.com/v1/audio/transcriptions` | `gpt-4o-mini-transcribe` (or `whisper-1`, `gpt-4o-transcribe`) | required |
| Groq | `https://api.groq.com/openai/v1/audio/transcriptions` | `whisper-large-v3-turbo` | required |
| Ollama | `http://localhost:11434/v1/audio/transcriptions` | an audio-capable model, e.g. `lfm3-audio` | not needed |

For Ollama, use a recent version and pull an audio model first: `ollama pull lfm3-audio`. Text-only models will return *"does not support audio input"*.

Also works with LiteLLM, LocalAI, faster-whisper-server/speaches, vLLM, etc.

### Local command (fully offline CLI)
Runs a shell command; `{file}` is replaced with the recorded 16 kHz mono WAV and the transcript is read from stdout.

**whisper.cpp** (fast on Apple Silicon):

```sh
brew install whisper.cpp
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Command (the default preset):

```
whisper-cli -m ~/.cache/whisper/ggml-base.en.bin -nt -np -f {file}
```

Use `ggml-small.en.bin` / `ggml-large-v3-turbo.bin` for better accuracy, or the non-`.en` models for other languages.

**openai-whisper** (Python, `pipx install openai-whisper`) — preset provided; slower on CPU.

Any other tool works too, as long as it prints the text to stdout.

## Install

**Prebuilt:** download `VoicePaste-1.0.zip` from [Releases](../../releases/latest), unzip it, move `VoicePaste.app` to Applications. It isn't notarized, so the first time either right-click → **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/VoicePaste.app
```

**From source** (needs Xcode or the Command Line Tools — `xcode-select --install`):

```sh
./make-cert.sh   # optional, once: stable signature so permissions survive rebuilds
./build.sh       # builds and installs to ~/Applications
./build.sh --dist  # makes a shareable zip in dist/
```

## Permissions

On first launch macOS asks for:

1. **Microphone** — to record you.
2. **Accessibility** — only to paste (it sends ⌘V). Without it, VoicePaste still copies the text to the clipboard.
3. **Speech Recognition** — only if you use the Apple engine.

If auto-paste stops working after updating the app, open System Settings → Privacy & Security → Accessibility, remove VoicePaste with **−**, and add it again.

## Tuning auto-stop

In Settings → Auto-stop:

- **Stop after a pause of** — raise it if you get cut off mid-thought.
- **Give up if silent for** — cancels if you say nothing.
- **Speech threshold** — lower if quiet speech is missed, raise in noisy rooms.

Turn on *Log mic levels* and run `/Applications/VoicePaste.app/Contents/MacOS/VoicePaste` from Terminal to see live levels.

## Notes

- Settings live in `~/.config/voicepaste/config.json` (readable only by you).
- ⌘⇧Space must be free — if another app (Hammerspoon, Raycast, Alfred…) uses it, VoicePaste will say so on launch.
- Requires macOS 13 or later. Universal binary (Apple Silicon + Intel).

## License

MIT — see [LICENSE](LICENSE).
