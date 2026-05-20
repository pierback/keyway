# Use a Perl-Hosted MediaRemote Helper

We decided to use an isolated helper backend that loads Keyway's private MediaRemote bridge through `/usr/bin/perl`. Direct calls from our own Objective-C executable can load the symbols but receive empty Now Playing results on macOS 26.4.1, while the Perl-hosted dylib path can list MediaRemote clients and metadata.

**Consequences**

- Private MediaRemote access stays behind a `MediaRemote Helper` adapter instead of spreading through the Swift app.
- Keyway diagnostics must clearly report when the helper path fails.
- The helper is a deliberate private-API workaround and is not App Store-safe.
