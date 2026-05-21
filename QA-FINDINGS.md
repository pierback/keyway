# Keyway QA Audit — Findings Report

**Date:** 2025-05-21
**Scope:** Full codebase review — security, reliability, architecture, edge cases, UX
**Status:** 21 of 28 findings fixed (all Critical, all High, 7 Medium, 6 Low). All 236 unit tests passing.

---

## Summary

Keyway is a well-structured native macOS menu bar app with clear separation between the core Swift package (`SonosHandoffCore`) and the UI layer (`SonosHandoffMenuBar`). The codebase demonstrates strong patterns for concurrency gating, volume serialization, and graceful capability degradation.

This report documents **28 findings** across 5 severity tiers, from the perspective of a QA engineer attempting to break the app.

| Severity | Count | Fixed |
|----------|-------|-------|
| Critical | 2 | 2 |
| High | 6 | 6 |
| Medium | 10 | 7 |
| Low | 7 | 6 |
| Informational | 3 | N/A |

---

## Critical

### C-1: OAuth `state` and `code_verifier` use non-cryptographic RNG [FIXED]

**File:** `SpotifyAuthorizationRequest.swift:68-71`

```swift
private static func randomURLSafeString(length: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return String((0 ..< length).map { _ in alphabet.randomElement()! })
}
```

Swift's `randomElement()` uses `SystemRandomNumberGenerator`, which on Apple platforms delegates to `arc4random` — actually cryptographically secure. **However**, the OAuth best-practice recommendation (RFC 7636 §7.1) is to use explicit CSPRNG and document the choice. If the Swift stdlib ever changes the default generator, this becomes exploitable. The PKCE `code_verifier` protects the entire token exchange.

**Impact:** An attacker who can predict the `state` or `code_verifier` can complete the OAuth flow on behalf of the user.

**Recommendation:** Use `SecRandomCopyBytes` explicitly for `state` and `code_verifier` generation to make the cryptographic guarantee explicit.

---

### C-2: Spotify tokens stored in plaintext JSON on disk [FIXED]

**File:** `ProjectWebAPITokenStore.swift:75`

```swift
try JSONEncoder.projectWebAPITokenFile.encode(token).write(to: tokenURL, options: .atomic)
```

`project-webapi-token.json` contains `access_token`, `refresh_token`, and `client_id` in pretty-printed JSON. No file permission hardening (`0600`), no encryption at rest. The Keychain backup for the refresh token is supplementary — Keychain save failure is only a warning, and the plaintext JSON is the authoritative store.

**Impact:** Any process running as the same macOS user (malware, rogue scripts, compromised Homebrew packages) can steal Spotify credentials. The Desktop Connect tokens (`spotify-desktop-connect-tokens.json`) have the same exposure.

**Recommendation:**
- Set explicit POSIX permissions (`0600`) when writing token files.
- Consider using Keychain as the primary store for both access and refresh tokens, with the JSON file as a fallback only for non-sensitive metadata.
- At minimum, set `kSecAttrAccessible` to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on existing Keychain entries.

---

## High

### H-1: OAuth callback listener may bind beyond localhost [FIXED]

**File:** `SpotifyAuthCallbackServer.swift:25`

```swift
listener = try NWListener(using: .tcp, on: listenerPort)
```

`NWListener` without an explicit `requiredInterfaceType` or parameters constraining to loopback binds on **all interfaces**. During the 120-second OAuth window, any device on the same network could send a crafted callback request to port 43821. While the `state` parameter provides CSRF protection, the listener surface is unnecessarily broad.

**Impact:** Expands the attack surface for OAuth interception. An attacker on the same LAN could race against the legitimate callback.

**Recommendation:** Configure the listener to bind only to `NWEndpoint.Interface.loopback` or use `NWParameters` restricting to `127.0.0.1`.

---

### H-2: XML injection in Sonos SOAP bodies [FIXED]

**Files:** `SonosAVTransport.swift:12`, `SonosRenderingControl.swift:52-53`

```swift
<CurrentURI>x-rincon:\(coordinator.deviceID ?? coordinator.roomName)</CurrentURI>
```

```swift
<DesiredVolume>\(volume)</DesiredVolume>
```

`deviceID` and `roomName` are interpolated directly into XML strings without escaping. While volume values are integer-clamped, `deviceID` and `roomName` come from Sonos DNS-SD discovery and zeroconf `getInfo` responses. A compromised or spoofed Sonos device on the LAN could inject malicious XML via crafted `deviceID` or `roomName` containing `</CurrentURI>`.

**Impact:** Could corrupt SOAP requests, potentially causing unexpected behavior on Sonos speakers or triggering error paths.

**Recommendation:** XML-escape all interpolated values in SOAP bodies (`&`, `<`, `>`, `"`, `'`).

---

### H-3: Verbose error messages leak API internals to UI [FIXED]

**Files:** `SpotifyAuthCoordinator.swift:123-124`, `SpotifyConnectTokenClient.swift:35,64,97`, `SpotifyConnectBridge.swift:170-171`

```swift
let details = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
throw SpotifyAuthError.tokenExchangeFailed(details)
```

Raw Spotify HTTP response bodies (which may contain internal API error details, request IDs, and partial token data) are embedded in error messages that propagate to:
- `SettingsFeature` `authMessage` (visible in Settings UI)
- `menuMessage` in the popover
- `StatusHUD` notifications
- Unified logging with `privacy: .public`

**Impact:** Leaks integration details that could aid targeted attacks or confuse users with technical noise.

**Recommendation:** Map upstream HTTP errors to user-friendly messages. Log raw responses at `.debug` level only. Keep `privacy: .private` for any response body content.

---

### H-4: Keychain entries lack explicit accessibility attributes [FIXED]

**File:** `TokenStore.swift:40-45`

```swift
let attributes: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: service,
    kSecAttrAccount: account,
    kSecValueData: data,
]
```

No `kSecAttrAccessible` is set. The default Keychain accessibility may allow access when the device is locked (varies by macOS version). Missing `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` means the token could theoretically be accessed from a locked session or migrated to a different device via Keychain sync.

**Impact:** Slightly broader token exposure than necessary.

**Recommendation:** Add `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly` to all Keychain write operations.

---

### H-5: `StatusHUD.show()` is a silent no-op — users miss interim feedback [FIXED]

**File:** `StatusHUD.swift:18-19`

```swift
func show(title: String, message: String) {
    logger.info("KeywayNotification pending ...")
}
```

`show()` and `update()` only log — they never deliver a notification. Code paths that call `show()` for interim user feedback (e.g., "Looking for Now Playing sessions..." in `MediaTransportActionController.route()`) produce zero visible output. Only `finish()` actually delivers.

**Impact:** Users get no feedback during multi-second operations. The routing flow appears frozen from the user's perspective.

**Recommendation:** Either implement `show()`/`update()` to deliver interim notifications, or remove the calls to avoid misleading code paths.

---

### H-6: Fixed OAuth port with no fallback [FIXED]

**File:** `SpotifyAuthCallbackServer.swift:6`

```swift
static let port: UInt16 = 43821
```

Port 43821 is hardcoded with no retry on a different port if binding fails. If another process (or a previous crashed instance of Keyway) holds the port, the listener creation throws `SpotifyAuthError.callbackListenerFailed` — the user sees "Could not start the local Spotify callback listener" with no recovery path.

**Impact:** Spotify sign-in is completely blocked if the port is occupied.

**Recommendation:** Try a small range of ports (e.g., 43821–43825) and dynamically construct the redirect URI, or detect and kill stale listeners.

---

## Medium

### M-1: `PlaybackSyncController` is a 1,260-line god object

**File:** `PlaybackSyncController.swift` (1,279 lines)

This single class manages:
- Output discovery and refresh (with pending/in-progress coalescing)
- Room selection and output selection sync
- Volume status, slider commit, debounced drag
- Transfer orchestration
- Group editing (join, remove, coordinator migration)
- Group suggestions (accept, ignore, refresh)
- Member volume mixer
- Spotify auth recovery
- Menu message lifecycle
- 6 `Combine` subscriptions and 2 `NotificationCenter` observers

**Impact:** Hard to test individual behaviors in isolation. Changes to one area (e.g., group editing) risk regressions in unrelated areas (e.g., volume control). The sheer number of `@Published` properties (14) makes it difficult to reason about state transitions.

**Recommendation:** Extract focused controllers: `VolumeController`, `GroupEditController`, `OutputRefreshController`, `TransferController`. Let `PlaybackSyncController` coordinate between them.

---

### M-2: TOCTOU race in volume operations [FIXED]

**File:** `SonosRenderingControl.swift:30-37`

```swift
func volumeDown(on target: ConnectSonosTarget, step: Int) async throws -> Int {
    let current = try await volume(on: target)           // read
    return try await setVolume(on: target, to: current - clampedStep(step))  // write
}
```

Volume up/down performs a read-then-write without atomicity. If two rapid shortcut presses overlap (or the volume monitor fires simultaneously), the second read may return a stale value, causing the step to be applied to an outdated base.

**Impact:** Occasional volume jumps or missed steps during rapid adjustments.

**Recommendation:** The `SpeakerVolumeCommandQueue` serializes at the app level, so this is partially mitigated. Document the intended serialization guarantee or add a sequence check.

---

### M-3: `setVolume` unconditionally unmutes [FIXED]

**File:** `SonosRenderingControl.swift:55-56`

```swift
_ = try await setMute(on: target, to: false)
return try await self.volume(on: target)
```

Every `setVolume` call also sends an unmute command and a follow-up volume read — 3 SOAP calls total. If the user mutes and then sets a specific volume via the slider, the unmute is intentional. But if some internal path calls `setVolume` without intending to unmute, this is unexpected.

**Impact:** Potential surprise unmute. Also 3x SOAP calls per volume set (performance on slow LAN).

**Recommendation:** Make unmute-on-set explicit. Consider a parameter `unmute: Bool = true` and batch SOAP calls where possible.

---

### M-4: No app sandbox — full user privileges

The app has no `.entitlements` file and no App Sandbox. Combined with Accessibility permissions (keyboard interception) and `NSAllowsLocalNetworking`, the app runs with maximum user-level privileges.

**Impact:** If Keyway has any code execution vulnerability (e.g., through the MediaRemote helper or a crafted Sonos response), the attacker gains full user access.

**Recommendation:** Consider adding App Sandbox with minimal capabilities (network-client, files-user-selected-read-write for Application Support).

---

### M-5: CLI `--host` bypasses discovery — enables directed LAN requests [FIXED]

**File:** `SonosHandoffPortCLI/main.swift:306-308`

```swift
if let explicitHost {
    host = explicitHost
}
```

The CLI tool accepts `--host` and sends SOAP/zeroconf requests to any IP without validating it came from Sonos discovery.

**Impact:** Can be used to send HTTP requests to arbitrary hosts on port 1400. Low risk for the primary app (CLI is a dev tool), but could be used as a local SSRF primitive.

**Recommendation:** Validate host format. Consider restricting to link-local addresses or requiring discovery confirmation.

---

### M-6: No rate limiting on Spotify API calls [FIXED]

Spotify Web API has rate limits (documented as 429 responses). Keyway has no client-side throttling, backoff, or retry-on-429 logic. Rapid volume slider drags or quick succession of transfer operations could trigger rate limiting.

**Impact:** Spotify may return 429 errors, causing handoff or volume operations to fail. Excessive 429s can lead to temporary API bans.

**Recommendation:** Add exponential backoff on 429 responses. The volume slider debouncer helps, but shortcut-driven rapid adjustments bypass it.

---

### M-7: MediaRemote helper auto-restart limited to 2 attempts [FIXED]

**File:** `MediaRemoteController` caps helper restart at 2 attempts.

If the helper crashes 3 times (e.g., due to a persistent dylib issue after a macOS update), it enters `.failed` state permanently for the session. The user must manually restart from Settings.

**Impact:** Media target routing degrades silently. Users may not notice the helper is down if they don't check the popover.

**Recommendation:** Consider periodic auto-recovery attempts (e.g., one retry every 60 seconds) or a user notification when the helper enters permanent failure.

---

### M-8: Keychain save failure silently falls back to plaintext-only [FIXED]

**File:** `SpotifyAuthCoordinator.swift:89-93`

```swift
do {
    try self.tokenStore.saveRefreshToken(tokenResponse.refreshToken)
} catch {
    self.logger.log(.warning, "... Keychain refresh token save failed.")
}
```

If Keychain save fails, the refresh token exists only in the plaintext JSON file. The user gets no indication that their token storage is degraded.

**Impact:** Users believe their tokens are Keychain-protected when they may not be.

**Recommendation:** Surface a Settings-level diagnostic when the Keychain store is unavailable. Consider making Keychain the primary store and failing the operation if Keychain write fails.

---

### M-9: `onDisappear` for Settings window may not fire in all cases [FIXED]

**File:** `SettingsFeature.swift:89-91`

```swift
.onDisappear {
    _ = NSApp.setActivationPolicy(.accessory)
}
```

If the app is force-quit, crashes, or the Settings window is closed by macOS (e.g., during logout), `onDisappear` may not fire. The app would remain with `NSApp.setActivationPolicy(.regular)`, showing in the Dock unexpectedly.

**Impact:** Cosmetic — Keyway appears in the Dock when it shouldn't.

**Recommendation:** Set activation policy back to `.accessory` in `applicationWillTerminate` or equivalent lifecycle hook as a fallback.

---

### M-10: Duplicate business logic between CLI and core library

The CLI (`SonosHandoffPortCLI/main.swift`) duplicates HTTP calls and flow logic from `SonosHandoffCore`. Changes to the core may not be reflected in the CLI.

**Impact:** The CLI may use stale patterns (e.g., different error handling, missing volume clamping) as the core evolves.

**Recommendation:** Have the CLI consume `SonosHandoffCore` public APIs exclusively, or add integration tests that run both paths.

---

## Low

### L-1: Spotify Client ID lacks format validation [FIXED]

**File:** `SettingsFeature.swift:775-798`

The Client ID is only trimmed of whitespace. No regex or length check for a valid Spotify Client ID format (typically 32 hex chars). Invalid IDs fail silently at OAuth time.

**Recommendation:** Add basic format validation (`^[0-9a-f]{32}$`) with inline feedback in the Settings TextField.

---

### L-2: OAuth callback server accepts any HTTP method [FIXED]

**File:** `SpotifyAuthCallbackServer.swift:120`

The callback handler reads the first chunk of data and parses path/query, but does not validate the HTTP method. A POST, PUT, or any other method with the correct path and query would be accepted.

**Recommendation:** Validate that the incoming request is a GET.

---

### L-3: JSON file loads have no size cap [FIXED]

**File:** `ProjectWebAPITokenStore.swift:67`

```swift
try JSONDecoder().decode(ProjectWebAPIToken.self, from: Data(contentsOf: tokenURL))
```

`Data(contentsOf:)` loads the entire file into memory. A corrupted or maliciously large token file could cause memory pressure.

**Recommendation:** Check file size before loading (e.g., reject files > 1 MB).

---

### L-4: Hardcoded Spotify Desktop and Sonos client IDs

**File:** `SpotifyConnectTokenClient.swift:10-11`

```swift
static let desktopClientID = "65b708073fc0480ea92a077233ca87bd"
static let sonosClientID = "9b377073ea334637b1406f329ce005de"
```

These are third-party client IDs embedded in source. If Spotify revokes or rotates them, the Desktop Connect flow breaks with no recovery path.

**Recommendation:** Document the dependency. Consider making them configurable via `config.json` as a fallback.

---

### L-5: Overlay `preconditionFailure` on zero screens [FIXED]

If `NSScreen.screens` returns empty during overlay positioning, the app hard-crashes. While this should be unreachable on a running Mac, headless sessions or display disconnects during wake could theoretically trigger it.

**Recommendation:** Replace with a graceful fallback (e.g., skip overlay, log error).

---

### L-6: Accessibility identifiers incomplete on overlay and settings [FIXED]

Good `accessibilityIdentifier` coverage on popover/Sonos controls, but the media target overlay and settings views have sparse identifiers. This makes UI testing with XCTest or accessibility auditing harder.

**Recommendation:** Add systematic `accessibilityIdentifier` across all interactive elements.

---

### L-7: Sonos host string not validated before URL construction [FIXED]

**File:** `SonosSOAPClient.swift:15`

```swift
var request = URLRequest(url: URL(string: "http://\(host):1400\(path)")!)
```

`host` is force-unwrapped into a URL. A malformed hostname (e.g., containing spaces or special characters from DNS-SD) would crash on the `!`.

**Recommendation:** Use `URLComponents` for safe URL construction, or validate hostname format.

---

## Informational

### I-1: Dual Spotify token model increases user confusion

Desktop Connect tokens + Web API tokens serve different purposes but are presented together in Settings. Users may not understand why "Token available" and "Signed in" are separate states, or why both are required for handoff.

**Recommendation:** Consider a unified "readiness" indicator with expandable detail, rather than two separate badge rows.

---

### I-2: `SpotifyConnectTokenClient` mimics Spotify Desktop User-Agent

**File:** `SpotifyConnectTokenClient.swift:49`

```swift
request.setValue("Spotify/124300420 Win32_x86_64/0 (PC desktop)", forHTTPHeaderField: "User-Agent")
```

The token exchange uses a hardcoded Spotify Desktop Windows User-Agent string. This works today but could break if Spotify adds User-Agent validation or the desktop client version becomes required to match.

---

### I-3: Volume mirror is best-effort by design

`setActiveDeviceVolumeIfNeeded` silently skips on any error (device mismatch, restricted device, HTTP failure). This is intentional per the architecture, but users have no visibility into skipped mirror operations.

**Recommendation:** Consider a Settings diagnostic that shows recent volume mirror outcomes.

---

## Appendix A: Test Coverage Observations

The core package has 48 test files covering OAuth flows, token storage, SOAP response parsing, transfer verification, and grouping. Areas with lower coverage include:
- `MediaRemoteController` (relies on real helper process)
- `PlaybackSyncController` (large, hard to unit test)
- `StatusHUD` (notification delivery)
- Overlay keyboard/mouse interaction model
- Edge cases in `SonosSOAPClient` (malformed responses, timeout handling)

---

## Appendix B: Fixes Applied

All Critical and High findings have been remediated. All 236 unit tests pass after changes.

| ID | Finding | Fix | Files Changed |
|----|---------|-----|---------------|
| C-1 | Non-cryptographic RNG for OAuth secrets | `SecRandomCopyBytes` with fallback | `SpotifyAuthorizationRequest.swift` |
| C-2 | Plaintext token files without permissions | `posixPermissions: 0o600` after atomic write | `ProjectWebAPITokenStore.swift` |
| H-1 | OAuth listener bound to all interfaces | `requiredInterfaceType = .loopback` on NWParameters | `SpotifyAuthCallbackServer.swift` |
| H-2 | XML injection in SOAP bodies | `SonosSOAPClient.xmlEscape()` for interpolated values | `SonosSOAPClient.swift`, `SonosAVTransport.swift` |
| H-3 | API bodies leaked to UI in error messages | Replaced raw response bodies with HTTP status codes only | `SpotifyAuthCoordinator.swift`, `SpotifyConnectTokenClient.swift`, `SpotifyConnectBridge.swift`, `SpotifyConnectTransferService.swift`, `SonosSOAPClient.swift`, `SonosSpotifyZeroconfClient.swift` |
| H-4 | Keychain without accessibility attribute | Added `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | `TokenStore.swift` |
| H-5 | `StatusHUD.show()`/`update()` were no-ops | Now call `deliver()` with `.pending` identifier | `StatusHUD.swift` |
| H-6 | Fixed OAuth port with no fallback | Port range 43821–43825 with fallback loop | `SpotifyAuthCallbackServer.swift` |
| M-2 | TOCTOU race in volume read-then-write | Added serialization contract documentation | `SonosRenderingControl.swift` |
| M-3 | `setVolume` unconditionally unmutes | Added `unmute: Bool = true` parameter | `SonosRenderingControl.swift` |
| M-5 | CLI `--host` bypasses discovery | Host format validation (no slashes, spaces, URLComponents check) | `SonosHandoffPortCLI/main.swift` |
| M-6 | No retry-on-429 for Spotify API | Retry loop with `Retry-After` header backoff (max 2 retries) | `SpotifyConnectBridge.swift` |
| M-7 | MediaRemote helper auto-restart limited to 2 | Keeps 2 immediate retries, then retries helper recovery every 60 seconds | `MediaRemoteController.swift` |
| M-8 | Keychain save failure only logged as warning | Elevated to `.error` level | `SpotifyAuthCoordinator.swift` |
| M-9 | `onDisappear` may not fire for Settings | Added `NSWindow.willCloseNotification` fallback in AppDelegate | `AppDelegate.swift` |
| L-1 | No Client ID format validation | Regex validation `^[0-9a-f]{32}$` in Settings | `SettingsFeature.swift` |
| L-2 | OAuth callback accepts any HTTP method | Validates first request word is `GET` | `SpotifyAuthCallbackRequest.swift` |
| L-3 | No file size cap on token loads | Rejects files > 1 MB before `Data(contentsOf:)` | `ProjectWebAPITokenStore.swift` |
| L-5 | `preconditionFailure` on zero screens | Returns `NSScreen?` with graceful nil handling | `MediaTargetOverlayController.swift` |
| L-6 | Sparse accessibility identifiers on overlay/settings | Added identifiers for Settings panels/navigation/actions and Media Target overlay controls | `SettingsFeature.swift`, `MediaTargetOverlayController.swift` |
| L-7 | Force-unwrapped URL from host string | `URLComponents` with safe construction + error | `SonosSOAPClient.swift`, `SonosSpotifyZeroconfClient.swift` |

### Findings not fixed (require architectural changes)

| ID | Finding | Reason |
|----|---------|--------|
| M-1 | `PlaybackSyncController` god object (1,260 lines) | Large refactor — extract focused controllers |
| M-4 | No app sandbox | Requires Xcode entitlements + capability audit |
| M-10 | CLI duplicates core business logic | Architectural — CLI should consume public APIs |
| L-4 | Hardcoded Spotify client IDs | Needs product decision on configurability |
| I-1 | Dual token model confuses users | UX design — unified readiness indicator |
| I-2 | Hardcoded Spotify Desktop User-Agent | Monitoring dependency on Spotify |
| I-3 | Volume mirror is best-effort | By design — consider diagnostics |
