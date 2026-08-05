# Authenticate Chromium App/Host IPC

## Status

Accepted on 2026-08-05.

## Decision

Keyway uses `KeywayChromiumBridgeIPC`, a small shared Swift module, for all communication between the macOS app and `keyway-chromium-native-host`. The transport is a private Unix-domain stream socket with length-prefixed JSON envelopes and a 4 MiB frame limit.

The boundary authenticates both peers using the audit token supplied by the connected socket. Security.framework must validate the peer against the expected code identifier, an Apple generic anchor, and team `7Q44SDV7BM`. The app accepts only `keyway-chromium-native-host`; the host accepts only `com.fpieringer.Keyway`. The endpoint parent directory is mode `0700` and the socket is mode `0600`.

`ChromiumBrowserExtensionController` remains the only mutable app authority for browser profiles, connection generations, pending requests, and published media targets. The shared module owns only framing, peer authentication, connection lifecycle, and bounded retry buffering. Chrome native messaging and its four-byte little-endian framing remain unchanged.

The protocol version, native-host name, extension ID, app bundle ID, native-host code identifier, and team ID have one source: `ChromiumBridgeProtocol/contract.json`. Generated Swift, JavaScript, and native-host manifest artifacts are checked for drift. This is a hard cutover; there is no distributed-notification or alternate-protocol fallback.

## Rationale

`DistributedNotificationCenter` cannot authenticate a sender. Any process in the login session could forge a browser snapshot, result, or app command, so filesystem secrecy and message correlation were not sufficient.

An anonymous `NSXPCListener` was evaluated first. Its endpoint can only be encoded by `NSXPCCoder`, so it cannot be handed to an independently launched Chrome native-messaging host through a normal file or environment contract. A named XPC service would add launchd and service-bundle lifecycle that the current browser-owned helper does not need. A Unix socket preserves the existing process ownership while allowing kernel-bound peer identity and strict permissions.

## Consequences

- Development and smoke peers must carry valid Apple Development signatures with the canonical identifiers and team.
- Unsigned, ad-hoc-signed, wrong-team, or wrong-identifier peers are rejected before any envelope is accepted.
- Native-host disconnects retire only their current generation. The extension consumes Chromium's expected disconnect error and reconnects with bounded backoff; neither the app nor the host reloads the extension runtime or browser tabs.
- The browser extension protocol remains version 4, and every consumer is generated from or checked against the canonical contract.
