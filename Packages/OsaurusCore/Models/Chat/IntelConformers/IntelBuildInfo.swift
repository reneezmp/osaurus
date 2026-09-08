//
//  IntelBuildInfo.swift
//  OsaurusCore (Intel fork)
//
//  Build-identity metadata for the Intel fork.
//
//  The fork keeps its OWN, independent version line
//  (`CFBundleShortVersionString`, e.g. 1.0.x) — that number describes THIS
//  build's user-facing state. These constants surface the upstream-sync
//  correspondence as *metadata* (shown in the About panel + release notes),
//  NOT as the version number. We deliberately do not peg the release number to
//  upstream's, because the fork amputates whole subsystems (MLX, voice,
//  sandbox, Vectura) and skips amputated/Tahoe-only commits — so a pegged
//  number would imply a parity we don't have.
//
//  ⚠️ SINGLE SOURCE OF TRUTH. Update `IntelBuildInfo` below whenever you run an
//  upstream sync, in lockstep with `docs/UPSTREAM_SYNC.md`. The release script
//  (`scripts/release/cut_intel_release.sh`) greps `upstreamBase` from this file
//  to stamp the release notes, so this is the only place the number lives.
//

import Foundation

/// Always-present, public accessor for the upstream-sync metadata. Lives
/// OUTSIDE the `#if OSAURUS_INTEL` guard so the App target (which does NOT
/// define the flag) can read it for the macOS About panel. Returns nil on the
/// Apple-Silicon build.
public enum OsaurusBuildInfo {
    /// Short label for the About-panel version line, e.g. "upstream 0.19.15".
    public static var upstreamShortLabel: String? {
        #if OSAURUS_INTEL
        return "upstream \(IntelBuildInfo.upstreamBase)"
        #else
        return nil
        #endif
    }

    /// Full one-line credit, e.g. "Intel fork · synced to upstream Osaurus
    /// 0.19.15 (d132b728)".
    public static var upstreamFullCredit: String? {
        #if OSAURUS_INTEL
        return
            "Intel fork · synced to upstream Osaurus \(IntelBuildInfo.upstreamBase) (\(IntelBuildInfo.upstreamCommit))"
        #else
        return nil
        #endif
    }
}

#if OSAURUS_INTEL
enum IntelBuildInfo {
    /// The upstream Osaurus version era this build is synced to (display only).
    static let upstreamBase = "0.24.7"

    /// The exact upstream commit last synced (short hash) — matches the
    /// "Last synced upstream commit" line in `docs/UPSTREAM_SYNC.md`.
    static let upstreamCommit = "7e109ade"
}
#endif
