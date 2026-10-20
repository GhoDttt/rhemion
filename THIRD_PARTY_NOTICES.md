# Third-party notices

Rhemion is licensed under the Mozilla Public License 2.0 (see [LICENSE](LICENSE) and [NOTICE](NOTICE)). It builds on the following work, with thanks. In the app, the full license texts are in `Rhemion.app/Contents/Resources/Licenses/` (About › Licenses & Notices opens this file).

## Included in the app

### FluidAudio
On-device speech recognition on Apple platforms (Core ML); runs Parakeet.
<https://github.com/FluidInference/FluidAudio>, Apache License 2.0.
The license text, and the licenses of the components FluidAudio carries (NemoTextProcessing, fastcluster, VBx and others), are included in the app.

### transcribe.cpp
Speech recognition library on ggml; the `rhemion-transcribe` helper uses it, unmodified, to run Whisper and Qwen3-ASR.
<https://github.com/handy-computer/transcribe.cpp>, release v0.4.0, MIT License. Copyright (c) 2026 The transcribe.cpp authors.
It includes ggml (MIT License) and other components listed in its THIRD-PARTY-LICENSES.md, included in the app.

### Mulish
Interface typeface. <https://github.com/googlefonts/mulish>
Copyright 2016 The Mulish Project Authors.
SIL Open Font License 1.1. Full text in `deploy/fonts/OFL.txt` and in the app.

## Speech models, downloaded when you choose them

The models are downloaded directly from Hugging Face to your Mac; they are not redistributed by this repository or bundled in the app. Rhemion is not affiliated with or endorsed by their authors or Hugging Face.

### Parakeet Ultra (the default)
Moondream's post-training of NVIDIA Parakeet TDT 0.6B v3; Core ML conversion by FluidInference.
<https://huggingface.co/moondream/parakeet-ultra>, <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>,
<https://huggingface.co/FluidInference/parakeet-ultra-coreml>
Creative Commons Attribution 4.0 International (CC BY 4.0). Changes: converted to Core ML by FluidInference; Rhemion uses it unchanged.

### Whisper Large v3 Turbo (Q5)
OpenAI Whisper, ggml conversion and Q5 quantization by the whisper.cpp project.
<https://github.com/openai/whisper>, <https://huggingface.co/ggerganov/whisper.cpp> (revision 5359861), MIT License.

### Qwen3-ASR 1.7B (Q5_K_M)
Speech recognition model by the Qwen team, Alibaba; GGUF conversion and Q5_K_M quantization by handy-computer.
<https://huggingface.co/Qwen/Qwen3-ASR-1.7B>, <https://huggingface.co/handy-computer/Qwen3-ASR-1.7B-gguf> (revision 0e0a596), Apache License 2.0.

## Part of macOS

### Apple Speech
Rhemion can use the speech recognition built into macOS 26 (SpeechAnalyzer). macOS downloads its language packs from Apple; nothing of it is distributed with Rhemion.
