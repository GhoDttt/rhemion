// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import AppKit
import AVFoundation
import RhemionASR
import RhemionAudio
import RhemionCore
import RhemionDelivery
import RhemionIPC
import RhemionRuntime

// Privacy hardening: force an owner-only umask before anything is created, so every file the
// runtime writes (WAV audio takes, the dictate JSONL of transcripts, rendered history notes,
// snapshots) is 0600 and every directory 0700 by default -- not world-readable 0644/0755. Explicit
// per-file permissions below are defense-in-depth on top of this.
umask(0o077)

// Uninstall: give back the language packs macOS holds for this program, then quit. Reservations belong to this
// executable's identity, so only it can release them.
if CommandLine.arguments.contains("--release-speech-packs") {
    let done = DispatchSemaphore(value: 0)
    Task { await AppleSpeech.releaseReservations(); done.signal() }
    _ = done.wait(timeout: .now() + 20)
    exit(0)
}

struct ConnectionSink: LineSink {
    let connection: UnixSocketConnection
    func send(_ line: String) { connection.send(line) }
}

func logToStderr(_ message: String) {
    FileHandle.standardError.write(Data("rhemion-runtime: \(message)\n".utf8))
}

let socketPath = RuntimePaths.stateDirectory().appendingPathComponent("runtime.sock").path
try RuntimePaths.ensureStateDirectory()

let metrics = Metrics.fromEnvironment()
let startupSettings = SettingsSnapshot.load()

// Startup reconcile + retention are wired below, after the shared `history` store exists, so every
// history mutation (live append, retention delete, audio expiry, reconcile) goes through ONE actor
// instance and can never race a parallel one. Both are fire-and-forget and never delay readiness.

// Composition root for capture: CaptureCoordinator owns enumeration, settings resolution and
// the warm AUHAL engine. This factory prepares one candidate and wires it through the conversion
// pipeline into a per-take WAV; the coordinator falls through to the next ranked candidate when
// preparation fails and runs without capture when none can be prepared.
// Routes the capture pipeline's converted samples to a throttled `.level` IPC event. `onLevel`
// is wired below, after `service` exists -- see the note on ThrottledLevelTap for why that
// ordering is safe (no capture take can begin before the runtime accepts its first connection).
let levelRouter = ThrottledLevelTap()

func makeCapture(for device: AudioDeviceInfo) throws -> TakeSink {
    let engine = AUHALCapture(deviceID: device.id)
    try engine.prepare()
    let pipeline = CapturePipeline(
        converter: AVAudioConverterAdapter(),
        ring: AudioRingBuffer(capacity: Int(AudioFormat.sampleRate) * 30),
        now: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
        levelTap: { samples in levelRouter.tap(samples) }
    )
    let controller = CaptureController(
        engine: engine,
        pipeline: pipeline,
        sinkFactory: WAVSinkFactory(),
        metrics: metrics
    )
    return CaptureControllerTakeSink(controller: controller)
}

let capture = CaptureCoordinator(
    listener: CoreAudioDeviceChangeListener(),
    deviceLossPolicy: .failTake,
    makeCapture: makeCapture,
    // Reading the status never prompts; preparing the input unit would. The app asks for access in its
    // Welcome window and restarts this runtime once it is granted.
    canCapture: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
    log: logToStderr
)

// Composition root for ASR: discover models at startup (whisper by scanning the search path;
// Parakeet from FluidAudio's shared cache) and register the PRESENT ones keyed by model id. Lives
// in makeModelRegistry(entries:snapshot:) so it is unit-tested -- an empty registry would make the
// runtime silently emit no transcript.
//
// MODEL SELECTION is live among REGISTERED models: RHEMION_ASR_MODEL pins one (debugging); otherwise
// the active model is the snapshot's `model`, re-read per take (see resolveModelID) so switching
// applies to the next dictation without a restart. A newly added dir/file (model_dirs) needs a
// restart to be discovered + registered.
let pinnedModelID = ProcessInfo.processInfo.environment["RHEMION_ASR_MODEL"]
let discoveredModels = ModelRegistry.discover(extraDirs: startupSettings.modelDirs)
let engineRegistry = makeModelRegistry(entries: discoveredModels, snapshot: startupSettings)
let startupModelID = ModelRegistry.startupID(desired: pinnedModelID ?? startupSettings.model, entries: discoveredModels)
let transcriber = Transcriber(registry: engineRegistry, defaultEngineID: startupModelID)

// Fresh-install / misconfig guard: if NO model is present, the runtime would otherwise start fine
// and only reveal the problem as a canceled take. Surface it loudly at startup instead.
if engineRegistry.ids.isEmpty {
    logToStderr("[model] WARNING: no recognition models found -- dictation will produce no transcript. "
        + "Run `rhemion models`; download \(ModelCatalog.defaultID) (FluidAudio cache) or add a whisper model dir via `model_dirs`.")
} else {
    logToStderr("[model] startup model=\(startupModelID); registered=[\(engineRegistry.ids.sorted().joined(separator: ", "))]")
}
logToStderr("[lang] languages=\(startupSettings.languages) recognition=\(startupSettings.recognition)")
Task { logToStderr("[apple] reserved packs=\(await AppleSpeech.reservedLanguages())") }

// The model to use for THIS take: the pinned env override, else the current snapshot's model
// (re-read from disk, matching how the mic setting hot-reloads) -- but only if it is a REGISTERED
// (present, startup-discovered) model; otherwise fall back to the startup model AND log it, so a
// typo'd/absent model id is visible in the log rather than silently ignored.
let resolveModelID: @Sendable () -> String = {
    let desired = pinnedModelID ?? SettingsSnapshot.load().model
    if engineRegistry.engine(id: desired) != nil { return desired }
    logToStderr("[model] requested '\(desired)' is not available; using '\(startupModelID)' (see `rhemion models`)")
    return startupModelID
}

// The language policy for THIS take: the current snapshot's language, re-read from disk each
// take (matching how the model selection above hot-reloads, so a language change applies to the
// next dictation without a restart).
let resolveLanguage: @Sendable () -> LanguagePolicy = {
    let snapshot = SettingsSnapshot.load()
    return snapshot.languages.isEmpty ? LanguagePolicy(setting: snapshot.language)
        : LanguagePolicy(languages: snapshot.languages, limit: snapshot.recognition == "limit")
}

// Apple Speech hears one language per take: the first of the user's languages it knows (they are in the user's
// order, the Mac's preferred languages on first run), else the first language.
let appleLanguage: @Sendable () async -> LanguagePolicy = {
    .only(await AppleSpeech.language(for: SettingsSnapshot.load().languages))
}

// Whisper and Qwen detect the language unless told: with one dictation language they are told, which saves Whisper
// a second of work per take; with several they detect among all they know.
let whisperLanguage: @Sendable () -> LanguagePolicy = {
    let languages = SettingsSnapshot.load().languages
    return languages.count == 1 ? .only(languages[0]) : resolveLanguage()
}

// A model in rhemion-transcribe, by what its file says: one that detects is told the language when the user has one
// (whisperLanguage); one that doesn't is told the first of the user's languages it knows, else its own first.
let helperProfiles = Dictionary(discoveredModels.compactMap { e in e.profile.map { (e.id, $0) } }, uniquingKeysWith: { a, _ in a })
let helperLanguage: @Sendable (String) -> LanguagePolicy? = { id in
    guard let profile = helperProfiles[id] else {
        return id.hasPrefix("whisper-") || id.hasPrefix("qwen3-asr") ? whisperLanguage() : nil
    }
    if profile.detects { return whisperLanguage() }
    let mine = SettingsSnapshot.load().languages
    guard let code = mine.first(where: profile.languages.contains) ?? profile.languages.first else { return nil }
    return .only(code)
}

// Warm the active model so every dictation is instant. Parakeet's first call otherwise pays a cold model
// load+compile (~20s the first time); since its actor serializes transcription, every dictation held during
// that window would queue and then flush in a burst (observed live). The active model starts as the startup
// model; when the user picks another (`.useModel`), the runtime prepares that one and only then frees the
// one it replaces, so a take already running finishes on the old model and only one model holds memory
// (16 GB Macs can't hold two). Whisper and Qwen run in the rhemion-transcribe helper, which holds its model the same way.
// `ModelWarmth` tells the app (via the `.devices` report) when the active model is ready, so it can show
// "Preparing speech model" instead of claiming ready while a first-time compile still runs.
final class ModelWarmth: @unchecked Sendable {
    private let lock = NSLock()
    private var active: String
    private var warm = false
    private var damaged = false
    private var generation = 0
    init(active: String) { self.active = active }

    var state: (active: String, warm: Bool, damaged: Bool) {
        lock.lock(); defer { lock.unlock() }; return (active, warm, damaged)
    }
    /// Start preparing `id`; the returned generation tells a finished prewarm whether it is still current.
    func begin(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        active = id; warm = false; damaged = false; generation += 1
        return generation
    }
    /// Record the result if no newer switch happened meanwhile; true when it was still current.
    func finish(_ gen: Int, warmed: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard gen == generation else { return false }
        warm = true; damaged = !warmed
        return true
    }
}
let warmth = ModelWarmth(active: startupModelID)

/// Prepare `id` (one retry), then free every other registered model. Never leaves the app on "Preparing"
/// forever: a model that cannot be prepared twice is reported as damaged, and the app offers a fresh download.
@Sendable func activate(_ id: String) async {
    let gen = warmth.begin(id)
    guard let engine = engineRegistry.engine(id: id) else { _ = warmth.finish(gen, warmed: true); return }
    let start = Date()
    var warmed = await engine.prewarm()
    if !warmed {
        logToStderr("[model] prewarm(\(id)) failed; retrying once")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        warmed = await engine.prewarm()
    }
    guard warmth.finish(gen, warmed: warmed) else { return }   // superseded by a newer switch
    logToStderr(warmed
        ? "[timing] prewarm(\(id)) done in \(String(format: "%.1f", Date().timeIntervalSince(start)))s"
        : "[model] prewarm(\(id)) failed twice; reported as damaged")
    for other in engineRegistry.ids where other != id {
        await engineRegistry.engine(id: other)?.unload()
    }
}
Task.detached(priority: .utility) { await activate(startupModelID) }

// Transcript producer: runs the selected engine over the WAV URL RuntimeService snapshotted
// at stop-time (passed in, not re-read here) -- reading `captureController.lastTakeURL` late,
// from inside this closure, would race a fast subsequent start+stop overwriting it. Nil only
// when capture is unavailable -- then there is no take WAV to transcribe.
let transcriptProducer: (@Sendable (String, URL) async -> TranscriptResult?)? = { @Sendable _, wav in
        // Drop accidental taps / silent holds BEFORE the engine sees them: an empty press-release
        // otherwise makes Parakeet hallucinate garbage (random letters/digits) that then gets pasted.
        guard let samples = try? WAVReader.readInt16Mono16k(wav), AudioGate.worthTranscribing(samples) else {
            return nil
        }
        let id = resolveModelID()
        let language = id == AppleSpeech.modelID ? await appleLanguage() : helperLanguage(id) ?? resolveLanguage()
        return await transcriber.run(wav: wav, engineID: id, language: language)
}

// Composition root for delivery: a hot-reloading dictionary store (the file need not exist
// yet -- DictionaryStore resolves to .empty until the app writes it) feeding a deterministic
// post-processing pipeline (Noop enhancer).
let dictStore = DictionaryStore(url: RuntimePaths.stateDirectory().appendingPathComponent("active/dictionary.json"))
let pipeline = DeliveryPipeline()
let deliveryPipeline: @Sendable (String, String) async -> DeliveryOutcome? = { _, raw in
    let delivered = await pipeline.run(raw: raw, dictionary: dictStore.current())
    return DeliveryOutcome(
        clean: delivered.clean,
        enhanced: delivered.enhanced,
        shouldDeliver: delivered.shouldDeliver,
        preDictionary: delivered.preDictionary
    )
}

// Machine history is appended per month; its human-readable monthly view is regenerated after delivery.
// No fixed directory: the store re-resolves the History root per commit, so it tracks a data_dir
// the settings snapshot may only gain after startup (the client may import it post-login).
let history = HistoryStore()

// Audio insurance (3.1): files created before this moment may be takes the previous runtime left behind.
let runtimeStartedAt = Date()
HistoryStore.orphanCutoff = runtimeStartedAt

let service = RuntimeService(
    coordinator: SessionCoordinator(),
    metrics: metrics,
    takeSink: capture,
    transcriptProducer: transcriptProducer,
    deliveryPipeline: deliveryPipeline,
    history: history,
    contextProvider: { targetPid in
        // Prefer resolving the exact pid the client bound to this take (the app the text is
        // inserted into) via a direct LaunchServices lookup, which — unlike frontmostApplication —
        // does not depend on activation tracking that a non-GUI helper process cannot observe
        // reliably. Fall back to the frontmost app only when no pid was sent.
        let app = targetPid.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
            ?? NSWorkspace.shared.frontmostApplication
        guard app?.localizedName != nil || app?.bundleIdentifier != nil else { return nil }
        return HistoryApplication(name: app?.localizedName, bundleID: app?.bundleIdentifier)
    },
    devicesProvider: {
        // The runtime's own view of what's pickable: models from the same discovery that builds the
        // engine registry, mics from the same CoreAudio enumeration the capture layer selects from —
        // so the app's Settings pickers can never list something selection wouldn't actually use.
        let snapshot = SettingsSnapshot.load()
        // Only the active model is prewarmed; any other model counts as warm (it loads on first use).
        let active = warmth.state
        let models = ModelRegistry.discover(extraDirs: snapshot.modelDirs).map {
            ModelOption(id: $0.id, label: $0.label, engine: $0.engine, found: $0.found,
                        warm: $0.id != active.active || active.warm,
                        damaged: $0.id == active.active && active.damaged,
                        languages: $0.profile?.languages, handling: $0.profile?.languageHandling.rawValue,
                        maxSeconds: $0.profile?.maxSeconds, softLimit: $0.profile?.softLimit ?? false)
        }
        let mics = CoreAudioDeviceEnumerator.inputDevices().map {
            MicOption(uid: $0.uid, name: $0.name, builtIn: $0.isBuiltIn)
        }
        return (models: models, mics: mics)
    },
    modelUser: { id in await activate(id) },
    modelDownloader: RuntimeService.fluidDownloader(replace: { warmth.state.damaged }),
    speechCheck: { wav in
        guard let samples = try? WAVReader.readInt16Mono16k(wav) else { return false }
        return AudioGate.worthTranscribing(samples)
    }
)

// Dictation explicitly uses failTake (also the coordinator default). The retarget policy is
// reserved for a future call-recording take that can define how partial audio spans the gap.
capture.setDeviceLossHandler { message in
    Task { await service.captureFailed(message: message) }
}

// Now that `service` exists, wire the level router to emit through it. See ThrottledLevelTap's
// header: this assignment happens strictly before `server.start` below, so before any capture
// take (and so any call to `levelRouter.tap`) can occur.
levelRouter.onLevel = { rms in
    Task { await service.emitLevel(rms) }
}

// Keep-warm heartbeat: after the initial prewarm, periodically run one tiny silent inference while
// idle so the model and its compiled ANE program stay resident. This guards against a pause "after
// a while" if the OS evicts the model during a long idle -- the whole point of the tool is to hear
// instantly, every time, not just right after startup. Skipped while a dictation is active so it
// never queues ahead of real audio on the engine's serial actor. Utility priority; ~100ms warm.
// Warms the active model (it follows `.useModel`): it is the one with a resident ANE program to keep hot;
// whisper models shell out per take and need no keep-warm. Skipped while the active model is still being
// prepared, so the heartbeat never races a switch.
Task.detached(priority: .utility) {
    while true {
        try? await Task.sleep(nanoseconds: 60_000_000_000)   // 60s
        if await service.isRecording() { continue }
        let active = warmth.state
        guard active.warm, !active.damaged, let engine = engineRegistry.engine(id: active.active) else { continue }
        await engine.prewarm()
    }
}

// Startup reconcile + journal auto-cleanup (retention), on the shared `history` actor. Retention runs
// at most once per calendar day. Transcript expiry deletes whole entries older than the transcript
// cutoff via the normal deletion path (record + audio + exported note); audio expiry then removes only
// the WAV of retained takes older than the (separate) audio cutoff, keeping the transcript. Both knobs
// default to off (0 = keep forever), so this is a complete no-op unless the user opts in.
Task.detached(priority: .utility) {
    let stateDir = RuntimePaths.stateDirectory(), historyDir = RuntimePaths.historyDirectory()
    let startupMonth = HistoryStore.month(Date())
    // Recover interrupted takes FIRST: the reconcile below deletes recordings no journal row points at.
    // An unreadable log could already hold any take: recover nothing rather than journal one twice.
    let known = await history.knownIDs()
    if known == nil { logToStderr("[spool] recovery skipped: a journal log could not be read") }
    let interrupted = known.map { SpoolRecovery.collect(historyDirectory: historyDir, stateDirectory: stateDir,
                                                        knownIDs: $0, startedAt: runtimeStartedAt) } ?? []
    if !interrupted.isEmpty {
        logToStderr("[spool] recovering \(interrupted.count) interrupted take(s)")
        await service.recoverInterruptedTakes(interrupted)
    }
    // Then clear recordings no journal row points at, in every month (recovery has taken what it could).
    let swept = await history.sweepOrphanAudio(createdBefore: runtimeStartedAt,
                                               inProgressOlderThan: runtimeStartedAt.addingTimeInterval(-SpoolRecovery.maxAge))
    if swept > 0 { logToStderr("[history] removed \(swept) orphan recording(s)") }
    if await history.reconcile(month: startupMonth) == nil {
        logToStderr("history startup reconcile failed for \(startupMonth)")
    }
    // Settings are re-read each pass, so enabling cleanup applies without a restart. Runs at most once
    // per calendar day, and ONLY when a knob is enabled — the day is never marked done while retention
    // is off, so enabling it later the same day still runs. Both delete and audio expiry go through the
    // shared `history` actor (serialized with live appends).
    while true {
        let s = SettingsSnapshot.load()
        let now = Date()
        let audioCutoff = s.audioRetentionCutoff(from: now)
        let transcriptCutoff = s.transcriptRetentionCutoff(from: now)
        if (audioCutoff != nil || transcriptCutoff != nil), HistoryRetention.shouldRunToday(stateDirectory: stateDir, now: now) {
            do {
                var deletedIDs = Set<String>()
                if let cutoff = transcriptCutoff {
                    deletedIDs = HistoryRetention.expiredTranscriptIDs(stateDirectory: stateDir, historyDirectory: historyDir, before: cutoff)
                    if !deletedIDs.isEmpty { _ = await history.deleteEntries(ids: deletedIDs) }
                }
                if let cutoff = audioCutoff {
                    _ = await history.expireAudio(before: cutoff, excludingIDs: deletedIDs)
                }
                try HistoryRetention.markRanToday(stateDirectory: stateDir, now: now)
            } catch { logToStderr("history retention failed: \(error)") }
        }
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)   // re-check hourly
    }
}

// Scheduled export: while export mode is "scheduled", export the transcript notes on the chosen
// interval. A marker records the last run, so an interval that elapsed while the runtime was off
// exports on the first tick after startup ("missed run at next start"). Settings are re-read each
// tick, so switching mode/interval applies within one tick. A no-op in "auto"/"manual" mode.
Task.detached(priority: .utility) {
    let stateDir = RuntimePaths.stateDirectory()
    while true {
        let snapshot = SettingsSnapshot.load()
        if let interval = snapshot.exportScheduleSeconds {
            let last = ScheduledExport.lastRun(stateDirectory: stateDir)
            if last == nil || Date().timeIntervalSince(last!) >= interval {
                do { _ = try await history.exportNow(); try ScheduledExport.markRun(stateDirectory: stateDir, at: Date()) }
                catch { logToStderr("scheduled export failed: \(error)") }
            }
        }
        try? await Task.sleep(nanoseconds: 300_000_000_000)   // re-check every 5 min
    }
}

let server = UnixSocketServer(path: socketPath)

try server.start { line, connection in
    let sink = ConnectionSink(connection: connection)
    // M1 assumes one command per line and a request-response client (one command at a
    // time per connection); pipelined clients could observe reordered events across
    // detached Tasks — revisit at the delivery milestone.
    Task { await service.handle(line: line, reply: sink) }
}

// Leave with the app. If Rhemion dies without stopping us (SIGTERM skips applicationWillTerminate, a
// crash, kill -9), a runtime left behind would share the state folder and socket with the next app's
// runtime. Watch the parent and exit as soon as it is gone. Exit WITHOUT server.stop(): by then the next
// runtime may already own runtime.sock, and stop() would unlink it; the next start replaces a stale one.
let parentPid = getppid()
let parentWatch: DispatchSourceProcess? = parentPid > 1
    ? DispatchSource.makeProcessSource(identifier: parentPid, eventMask: .exit, queue: .global()) : nil
parentWatch?.setEventHandler {
    FileHandle.standardError.write(Data("rhemion-runtime: parent \(parentPid) exited; exiting\n".utf8))
    exit(0)
}
parentWatch?.resume()
if parentPid > 1, kill(parentPid, 0) != 0 { exit(0) }   // the parent died before the watch was armed

FileHandle.standardError.write(Data("rhemion-runtime listening on \(socketPath)\n".utf8))
dispatchMain()
