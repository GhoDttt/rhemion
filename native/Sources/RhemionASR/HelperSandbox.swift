// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Runs rhemion-transcribe inside a macOS sandbox. A model file is data, but native code parses it; a damaged or
/// hostile file that breaks the parser could otherwise act with the user's rights. Under this profile the helper
/// has no network at all, cannot write anywhere, and of the home folder may read only the model file, the folder
/// the takes are written to and the folder it lives in. Everything outside the home folder (system frameworks,
/// Metal) stays readable, so the GPU path works unchanged.
enum HelperSandbox {
    static let launcher = "/usr/bin/sandbox-exec"

    static let profile = """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (deny file-read* (subpath (param "HOME")))
        (allow file-read* (literal (param "MODEL")) (subpath (param "TAKES")) (subpath (param "HELPER_DIR")))
        """

    /// The executable and arguments that start `helper arguments…` in the sandbox. Without sandbox-exec on this
    /// Mac it says so in the log and starts the helper as is.
    static func command(helper: String, arguments: [String], model: String, takes: URL?) -> (executable: String, arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: launcher) else {
            FileHandle.standardError.write(Data("[security] sandbox-exec is missing; rhemion-transcribe runs without its sandbox\n".utf8))
            return (helper, arguments)
        }
        let params = [
            "HOME": real(NSHomeDirectory()),
            "MODEL": real(model),
            // The probe has no takes; a path that cannot exist keeps the rule valid and grants nothing.
            "TAKES": takes.map { real($0.path) } ?? "/nonexistent/rhemion-takes",
            "HELPER_DIR": real((helper as NSString).deletingLastPathComponent),
        ]
        let defines = params.sorted { $0.key < $1.key }.flatMap { ["-D", "\($0.key)=\($0.value)"] }
        return (launcher, defines + ["-p", profile, helper] + arguments)
    }

    /// The sandbox matches real paths: /var is /private/var, and a folder may be a symlink.
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
