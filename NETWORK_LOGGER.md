# Network & Video Chunk Logger Documentation

Better Player includes real-time network and video chunk logging for HLS, DASH, and progressive streams on Android (ExoPlayer) and iOS (AVPlayer).

---

## 1. Quick Start: How to Access the Logs

### A. Using the Stream (Recommended for Custom Loggers & UI)
```dart
controller.networkLogStream.listen((BetterPlayerNetworkLog log) {
  print('[NETWORK] ${log.fileName} | ${log.formattedSize} | ${log.formattedDuration} | Status: ${log.statusCode}');
  
  if (log.isMediaChunk) {
    print('Chunk URL: ${log.url}');
  }
});
```

### B. Using Dedicated Listener
```dart
controller.addNetworkLogListener((BetterPlayerNetworkLog log) {
  // Handle log
});

// To remove:
controller.removeNetworkLogListener(listener);
```

### C. Using Standard Event Listener
```dart
controller.addEventsListener((BetterPlayerEvent event) {
  if (event.betterPlayerEventType == BetterPlayerEventType.networkLog) {
    final BetterPlayerNetworkLog log = event.parameters!['networkLog'];
    print('Log from event: ${log.url}');
  }
});
```

### D. Using the Built-in DevTools Network Tab Inspector Widget
```dart
// Embedded Widget
BetterPlayerNetworkLogsViewer(controller: _betterPlayerController)

// Or as a Modal BottomSheet
BetterPlayerNetworkLogsViewer.showModal(context, controller: _betterPlayerController);
```

---

## 2. Shared Log Details (`BetterPlayerNetworkLog`)

Every log event emitted by the stream or listeners contains a strongly typed `BetterPlayerNetworkLog` with the following properties:

### 1. Request Info
- `id` (`String`): Unique request/task ID.
- `url` (`String`): Full URL of the chunk or manifest (e.g. `https://example.com/stream/segment_1.ts`).
- `fileName` (`String`): File or chunk name extracted from URL (e.g. `segment_1.ts` or `master.m3u8`).
- `httpMethod` (`String`): HTTP method used (`GET`, `POST`, `HEAD`).
- `phase` (`BetterPlayerNetworkLogPhase`): Lifecycle state of the request (`start`, `completed`, `canceled`, `error`).
- `dataType` (`BetterPlayerNetworkDataType`): Type of content loaded:
  - `manifest`: Master or variant playlist (`.m3u8`, `.mpd`).
  - `mediaSegment`: Video/Audio segment chunk (`.ts`, `.m4s`, `fmp4`).
  - `initialization`: Init segment header (`init.mp4`).
  - `drmKey`: Encryption key or DRM license (`.key`).
  - `subtitles`: Subtitle segment (`.vtt`, `.srt`).
  - `unknown`: Unclassified request.
- `trackType` (`String?`): Track type (`video`, `audio`, `text`).
- `timestamp` (`DateTime`): Timestamp when event occurred.

### 2. Performance & Transfer Stats
- `statusCode` (`int?`): HTTP status code (`200`, `206`, `404`, `500`, etc.).
- `bytesLoaded` (`int`): Total bytes downloaded.
- `formattedSize` (`String`): Human readable size (`1.2 MB`, `450 KB`, `12 B`).
- `durationMs` (`int`): Transfer duration in milliseconds.
- `formattedDuration` (`String`): Formatted duration (`120 ms`, `1.50 s`).
- `serverAddress` (`String?`): Server IP address or hostname.

### 3. Media Metadata (for video/audio chunks)
- `bitrate` (`int?`): Bitrate in bits per second (bps).
- `formattedBitrate` (`String?`): Formatted bitrate (`2.50 Mbps`, `800 kbps`).
- `width` (`int?`): Video track width in pixels.
- `height` (`int?`): Video track height in pixels.
- `mediaStartTimeMs` (`int?`): Media start time in milliseconds.
- `mediaEndTimeMs` (`int?`): Media end time in milliseconds.
- `errorMessage` (`String?`): Error description if request failed.
- `extra` (`Map<String, dynamic>?`): Raw native platform metadata.

### 4. Helper Flags
- `isHls` (`bool`): `true` if this is an HLS chunk (`.ts`, `.m4s`) or manifest (`.m3u8`).
- `isMediaChunk` (`bool`): `true` if this is a video/audio segment chunk.
- `isSuccessful` (`bool`): `true` if request completed without error and status is `2xx`/`3xx`.
