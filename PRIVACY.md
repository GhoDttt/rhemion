# Privacy

Rhemion is built so that what you say stays on your Mac.

## What happens to your voice

- Audio is captured only while you dictate: while the key is held, or while hands-free recording is on.
- Recognition runs on your Mac. Audio and text are not sent anywhere.
- The recognized text is inserted into the focused field. When Rhemion pastes it, it puts the previous clipboard content back afterwards, unless another app has changed the clipboard in the meantime. The pasted text is marked so that clipboard managers can skip it.
- A dictation you cancel with Esc twice is kept in the Journal for 24 hours, so a cancel by mistake can be brought back, and then deleted. You can turn this off or change how long in Settings › Journal. Recordings shorter than a second are never kept.

## What is stored, and where

| Data | Location | Removed by |
|---|---|---|
| Settings and dictionary, with the dictionary's previous version | `~/.local/state/rhemion-v3/active/` | Clear Data, Uninstall |
| Journal: transcripts | `~/.local/state/rhemion-v3/log/` | Clear Data, Uninstall, Journal cleanup |
| Journal: a copy for opening it quickly, and its marks | `~/.local/state/rhemion-v3/journal-cache/` (holds the transcripts, readable only by you), `journal-marks.json` and `journal-inserted-again.json` in `~/.local/state/rhemion-v3/` | Kept in step with the journal; Clear Data, Uninstall |
| Journal: audio | `~/Library/Application Support/Rhemion/history/` | Clear Data, Uninstall, Journal cleanup |
| Speech models | Parakeet: `~/Library/Application Support/FluidAudio/Models/`. Whisper and Qwen3-ASR: `~/.local/share/whisper/`. Model files you put in a folder you added stay where you put them. | Settings › Models › Remove, Clear Data, Uninstall (your choice) |
| Apple Speech language packs | Kept by macOS for Rhemion while you use Apple Speech | Uninstall gives them back, so macOS can remove packs no other app uses |
| Logs | `~/.local/state/rhemion-v3/app.log`, `runtime.log` (kept 7 days, 15 MB at most) | Automatically; Clear Data, Uninstall |
| Caches | `~/Library/Caches/` and the temporary folder, under Rhemion's names | Clear Data, Uninstall |
| Exported transcripts | A folder you choose. Export is off until you turn it on and pick the folder. | Only if you ask: Settings › Journal › Export, or Clear Data |

Logs record technical events: start and stop, timings, text length in bytes, microphone names, errors. They do not record what you said, and they never contain audio.

## Network

- Rhemion goes online only to download a speech model, when you ask for it in the Welcome window or in Settings › Models. The models come from Hugging Face, which sees the request like any download (IP address, time): Parakeet from `huggingface.co/FluidInference`, Whisper from `huggingface.co/ggerganov/whisper.cpp`, Qwen3-ASR from `huggingface.co/handy-computer`. Each file is checked against its published fingerprint (SHA-256) before it is used.
- Apple Speech is part of macOS. When you choose it, macOS may download the language pack from Apple.
- Recognition works offline.
- Whisper, Qwen3-ASR and any model file you add run in a separate helper inside a macOS sandbox: it cannot connect to the network, cannot write files, and of your files can read only the model and the recording it is turning into text. A damaged or hostile model file has nothing to send and no way to send it.
- Rhemion has no analytics, crash reporting, telemetry, account or update check.

## Permissions

Accessibility (notice the dictation key, insert text, read a selection for the dictionary) and Microphone (hear you while you dictate; macOS may list Rhemion's helper `rhemion-runtime` separately). Uninstall removes Rhemion's entries from these lists.

## Contact

Questions: open an issue. Security problems: see [SECURITY.md](SECURITY.md).
