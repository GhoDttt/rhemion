// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

// rhemion-transcribe: keeps one model loaded (Whisper .bin or any transcribe.cpp GGUF, e.g. Qwen3-ASR) and
// transcribes takes for the Rhemion runtime.
//
// Usage: rhemion-transcribe <model>
//        rhemion-transcribe --probe <model>   prints what the model is and exits:
//          "model\t<family>\t<variant>\t<languages, comma-separated>\t<detects 0|1>\t<punctuation 0|1>\t<max audio ms, 0 = none>\t<name>"
//          <name> is the model's own name from its file (GGUF general.name), empty if it has none.
// Talks over its own stdin/stdout (the runtime is its parent; nothing else can reach it), one line each way:
//   on start      -> "ready"                    or "err\t<message>" and exit 1
//   "<lang>\t<wav>" -> "ok\t<text>\t<ms>"       or "err\t<message>"
// <lang> is an ISO 639-1 code, or "auto" to detect it. <wav> is a 16 kHz mono 16-bit WAV file. In <text>,
// backslash, tab and newline are written \\ \t \n. The library's own log goes to stderr.

#include "transcribe.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

static std::string escape(const std::string &s) {
    std::string out;
    for (char c : s) {
        if (c == '\\') out += "\\\\";
        else if (c == '\t') out += "\\t";
        else if (c == '\n' || c == '\r') out += "\\n";
        else out += c;
    }
    return out;
}

static bool read_wav(const std::string &path, std::vector<float> &pcm, std::string &error) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { error = "cannot open " + path; return false; }
    std::vector<char> data((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    auto u16 = [&](size_t i) { return uint16_t(uint8_t(data[i]) | uint8_t(data[i + 1]) << 8); };
    auto u32 = [&](size_t i) { return uint32_t(u16(i)) | uint32_t(u16(i + 2)) << 16; };
    if (data.size() < 12 || std::memcmp(data.data(), "RIFF", 4) != 0 || std::memcmp(data.data() + 8, "WAVE", 4) != 0) {
        error = "not a WAV file"; return false;
    }
    bool format_ok = false;
    for (size_t i = 12; i + 8 <= data.size();) {
        uint32_t size = u32(i + 4);
        size_t body = i + 8;
        if (body + size > data.size()) size = uint32_t(data.size() - body);
        if (std::memcmp(data.data() + i, "fmt ", 4) == 0 && size >= 16) {
            format_ok = u16(body) == 1 && u16(body + 2) == 1 && u32(body + 4) == 16000 && u16(body + 14) == 16;
            if (!format_ok) { error = "expected 16 kHz mono 16-bit PCM"; return false; }
        } else if (std::memcmp(data.data() + i, "data", 4) == 0) {
            if (!format_ok) { error = "data before format"; return false; }
            pcm.resize(size / 2);
            for (size_t k = 0; k < pcm.size(); k++) pcm[k] = int16_t(u16(body + 2 * k)) / 32768.0f;
            return true;
        }
        i = body + size + (size & 1);
    }
    error = "no audio in WAV"; return false;
}

// What a model file is, read from the model itself (its GGUF header and the family's capabilities), so Rhemion
// lists any family transcribe.cpp runs without a table of its own. Loads on the CPU: nothing is compiled.
static int probe(const char *path) {
    transcribe_model_load_params load;
    transcribe_model_load_params_init(&load);
    load.backend = TRANSCRIBE_BACKEND_CPU;
    transcribe_model *model = nullptr;
    transcribe_status st = transcribe_model_load_file(path, &load, &model);
    if (st != TRANSCRIBE_OK) { std::cout << "err\t" << escape(transcribe_status_string(st)) << std::endl; return 1; }
    transcribe_capabilities caps;
    transcribe_capabilities_init(&caps);
    if (transcribe_model_get_capabilities(model, &caps) != TRANSCRIBE_OK) {
        std::cout << "err\tno capabilities" << std::endl; transcribe_model_free(model); return 1;
    }
    std::string langs;
    for (int i = 0; i < caps.n_languages; i++) langs += (i ? "," : "") + std::string(caps.languages[i]);
    std::cout << "model\t" << escape(transcribe_model_arch_string(model)) << "\t" << escape(transcribe_model_variant_string(model))
              << "\t" << langs << "\t" << (caps.supports_language_detect ? 1 : 0)
              << "\t" << (transcribe_model_supports(model, TRANSCRIBE_FEATURE_PNC) ? 1 : 0)
              << "\t" << caps.max_audio_ms;
    const char *name = transcribe_model_meta_val_str(model, "general.name");
    std::cout << "\t" << escape(name ? name : "") << std::endl;
    transcribe_model_free(model);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && std::strcmp(argv[1], "--probe") == 0) return probe(argv[2]);
    if (argc != 2) { std::fprintf(stderr, "usage: rhemion-transcribe [--probe] <model>\n"); return 2; }
    std::ios::sync_with_stdio(false);

    transcribe_session *session = nullptr;
    transcribe_status st = transcribe_open(argv[1], nullptr, nullptr, &session);
    if (st != TRANSCRIBE_OK) {
        std::cout << "err\tcannot load " << escape(argv[1]) << ": " << transcribe_status_string(st) << std::endl;
        return 1;
    }
    {
        // Warm up once on half a second of silence, so the GPU kernels are built before the first take. In its
        // sandbox the helper cannot keep Metal's shader cache, and the first take would otherwise pay for it.
        std::vector<float> silence(8000, 0.0f);
        transcribe_run_params warm;
        transcribe_run_params_init(&warm);
        warm.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
        warm.language = "en";
        transcribe_run(session, silence.data(), int(silence.size()), &warm);
    }
    std::cout << "ready" << std::endl;

    std::string line;
    while (std::getline(std::cin, line)) {
        size_t tab = line.find('\t');
        if (tab == std::string::npos) { std::cout << "err\tbad request" << std::endl; continue; }
        std::string lang = line.substr(0, tab), path = line.substr(tab + 1);

        std::vector<float> pcm;
        std::string error;
        if (!read_wav(path, pcm, error)) { std::cout << "err\t" << escape(error) << std::endl; continue; }

        auto start = std::chrono::steady_clock::now();
        transcribe_run_params params;
        transcribe_run_params_init(&params);
        params.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
        params.language = lang == "auto" ? nullptr : lang.c_str();
        st = transcribe_run(session, pcm.data(), int(pcm.size()), &params);
        if (st != TRANSCRIBE_OK) { std::cout << "err\t" << escape(transcribe_status_string(st)) << std::endl; continue; }

        std::string text = transcribe_full_text(session);
        size_t a = text.find_first_not_of(" \n"), b = text.find_last_not_of(" \n");
        text = a == std::string::npos ? "" : text.substr(a, b - a + 1);
        long ms = long(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count());
        std::cout << "ok\t" << escape(text) << "\t" << ms << std::endl;
    }
    transcribe_close(session);
    return 0;
}
