# Performance Guard (`performance-guard.koplugin`)

A KOReader plugin for Android and Onyx Boox e-ink devices that eliminates Android Application Not Responding (ANR) freezes, gesture catch-up flurries, and MicroSD card flash write stalls when reading image-heavy files such as manga and comic archives.

## My Use Case

I read manga CBZ archives on an Onyx Boox e-ink tablet. Because the files take up significant storage, they are stored on a large external MicroSD card while KOReader runs on fast internal storage.

When reading image-heavy manga archives, I occasionally encountered severe freezes during page turns:
1. Large image decompression (2000x3000 JPEG/PNG buffers) combined with LuaJIT garbage collection would block the single UI thread.
2. During the freeze, tapping or swiping repeatedly caused Android's input queue to accumulate touch events.
3. If the stall exceeded 5 seconds, Android triggered an Application Not Responding (ANR) dialog.
4. When tapping "Wait", Android only extended the timer for the first stalled touch event. Because subsequently queued touch events had timestamps that were already older than 5 seconds, Android immediately fired another ANR dialog in an infinite loop until KOReader was force-closed.
5. If the freeze cleared before the ANR timed out, KOReader drained the entire backlog at once, turning 5 to 10 pages in a rapid "catch-up flurry".
6. Furthermore, KOReader by default created `.sdr` metadata folders alongside each book on the external MicroSD card. Writing progress updates synchronously to the exFAT MicroSD card triggered flash controller erase-block cycles, stalling the main thread for an additional 500ms to 2000ms per page turn.

I built `performance-guard.koplugin` to permanently solve these issues:
- **Anti-ANR Input Guard**: Detects main loop latency stalls (> 1.2s). When a freeze occurs, intermediate buffered taps and swipes are cleanly coalesced into a single gesture corresponding to the latest swipe or tap direction, eliminating the multi-page catch-up flurry.
- **ANR Loop Breaker**: Adds a 500ms post-focus guard window when returning from Android system dialogs. If the user taps "Wait" on an ANR prompt, stale expired gestures sitting in the queue are safely discarded, allowing KOReader to recover immediately without re-triggering the ANR.
- **MicroSD SDR Centralization**: Automatically redirects `.sdr` metadata writes for all books on external storage to fast internal storage (`/sdcard/koreader/docsettings/`), completely eliminating synchronous MicroSD write latency during page turns while preserving fallback loading of existing MicroSD metadata.
- **Metadata Migration Tool**: Includes a one-click migration utility to scan, safely copy, verify, and clean up existing `.sdr` folders from the MicroSD card to internal storage.

## General Use Case

This plugin is designed for any KOReader user experiencing reading latency, multi-page skipping, or ANR prompts on Android e-ink devices, particularly when:
- Reading CBZ, CBR, or scanned PDF image archives.
- Storing book libraries on external MicroSD cards or USB storage.
- Using e-ink devices with constrained single-thread memory bandwidth.

### Key Features
- **Anti-ANR Input Throttling**: Coalesces queued touch events during render latency spikes into a single latest gesture.
- **Post-Focus Stale Gesture Discarding**: Prevents the infinite Android ANR loop when clicking "Wait".
- **External Storage SDR Redirection**: Moves book metadata sidecars (`.sdr`) from slow external flash cards to fast internal UFS storage.
- **One-Click MicroSD Migration**: Safely migrates existing `.sdr` folders from external storage into internal storage with byte-size verification before source cleanup.
- **In-App Device Menu**: Accessible directly from KOReader's **Device** menu tab with real-time hardware status and toggleable guards.

## Dependencies

- [KOReader](https://github.com/koreader/koreader): Document viewer running on Android or Onyx Boox hardware.

### Recommended Complementary Integrations
- [kokomga-bookshelf-bridge.koplugin](https://github.com/oauei/kokomga-bookshelf-bridge.koplugin): Provides decoupled reading progress sync, deferring Komga server progress pushes until 5 seconds of reading inactivity or document close.

## Installation

Clone this repository into your KOReader plugins directory:

```bash
cd <koreader-directory>/plugins/
git clone https://github.com/oauei/performance-guard.koplugin.git
```

Restart KOReader. You can access the plugin settings and run the MicroSD migration under the **Device** menu in KOReader.

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
