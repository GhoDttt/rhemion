// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FluidAudio
import RhemionCore

extension CatalogModel {
    /// The FluidAudio version behind a Parakeet catalogue entry (nil for every other engine).
    var parakeetVersion: AsrModelVersion? {
        switch id {
        case "parakeet-ultra": return .ultra
        case "parakeet-v3": return .v3
        case "parakeet-v2": return .v2
        default: return nil
        }
    }
}
