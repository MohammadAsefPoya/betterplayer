# Network & Video Chunk Logging (Network Tab Inspector)

Better Player includes built-in real-time network request and video chunk logging for HLS, DASH, and progressive video streams on Android (ExoPlayer) and iOS (AVPlayer).

This feature captures every network interaction initiated by the media player—including HLS video/audio segments (`.ts`, `.m4s`), master and media playlists (`.m3u8`, `.mpd`), DRM license keys, and subtitle files—and exposes them directly to your Flutter app like the **Network Tab** in browser DevTools.

---

## 1. How to Access Network Logs in Your Project

There are four ways to consume network logs in your Flutter application:

### Option A: Reactive Stream (`networkLogStream`)
Listen to the broadcast stream on `BetterPlayerController`:

```dart
late BetterPlayerController _controller;
StreamSubscription<BetterPlayerNetworkLog>? _logSubscription;

@override
void initState() {
  super.initState();
  _controller = BetterPlayerController(
    const BetterPlayerConfiguration(aspectRatio: 16 / 9),
  );
  _controller.setupDataSource(
    BetterPlayerDataSource.network("https://example.com/hls/master.m3u8"),
  );

  // Subscribe to real-time network logs
  _logSubscription = _controller.networkLogStream.listen((BetterPlayerNetworkLog log) {
    print('-----------------------------------------');
    print('Request ID:     ${log.id}');
    print('URL:            ${log.url}');
    print('Phase:          ${log.phase.name}');
    print('Data Type:      ${log.dataType.name}');
    print('Status Code:    ${log.statusCode}');
    print('Bytes Loaded:   ${log.formattedSize} (${log.bytesLoaded} B)');
    print('Duration:       ${log.formattedDuration} (${log.durationMs} ms)');
    if (log.formattedBitrate != null) {
      print('Bitrate:        ${log.formattedBitrate}');
    }
  });
}

@override
void dispose() {
  _logSubscription?.cancel();
  _controller.dispose();
  super.dispose();
}
```

---

### Option B: Dedicated Listener (`addNetworkLogListener`)
Add or remove dedicated callback listeners:

```dart
void _onNetworkLog(BetterPlayerNetworkLog log) {
  if (log.isMediaChunk) {
    print('New media chunk downloaded: ${log.fileName} (${log.formattedSize})');
  }
}

// Register listener
_controller.addNetworkLogListener(_onNetworkLog);

// Unregister listener when done
_controller.removeNetworkLogListener(_onNetworkLog);
```

---

### Option C: Unified Event Listener (`addEventsListener`)
If you already use `addEventsListener`, network logs are also posted as standard `BetterPlayerEvent` instances with `BetterPlayerEventType.networkLog`:

```dart
_controller.addEventsListener((BetterPlayerEvent event) {
  if (event.betterPlayerEventType == BetterPlayerEventType.networkLog) {
    final BetterPlayerNetworkLog log = event.parameters!['networkLog'];
    print('Network Event: ${log.url} -> ${log.statusCode}');
  }
});
```

---

### Option D: Built-in Network Inspector UI Widget (`BetterPlayerNetworkLogsViewer`)
Better Player includes a ready-to-use DevTools-like UI widget that you can embed in your screen or present as a modal bottom sheet:

#### 1. Embedded Widget:
```dart
Column(
  children: [
    AspectRatio(
      aspectRatio: 16 / 9,
      child: BetterPlayer(controller: _controller),
    ),
    Expanded(
      child: BetterPlayerNetworkLogsViewer(
        controller: _controller,
      ),
    ),
  ],
)
```

#### 2. Modal Bottom Sheet:
```dart
IconButton(
  icon: const Icon(Icons.network_check),
  onPressed: () {
    BetterPlayerNetworkLogsViewer.showModal(
      context,
      controller: _controller,
    );
  },
)
```

---

## 2. Details and Properties Shared in Each Log Entry

Every log event provides a strongly typed `BetterPlayerNetworkLog` object with the following fields:

### Core Request Properties

| Property | Type | Description | Example |
| :--- | :--- | :--- | :--- |
| `id` | `String` | Unique identifier / task ID for the network request. | `"1042"` |
| `url` | `String` | The complete URL of the chunk, playlist, segment, or key. | `"https://cdn.example.com/hls/1080p_0045.ts"` |
| `fileName` | `String` | Extracted file/segment name portion of the URL. | `"1080p_0045.ts"` |
| `httpMethod` | `String` | HTTP Request method. | `"GET"`, `"POST"`, `"HEAD"` |
| `phase` | `BetterPlayerNetworkLogPhase` | Current lifecycle phase of the request. | `start`, `completed`, `canceled`, `error` |
| `dataType` | `BetterPlayerNetworkDataType` | Classification of the content being fetched. | `manifest`, `mediaSegment`, `initialization`, `drmKey`, `subtitles`, `unknown` |
| `trackType` | `String?` | Track media type if applicable. | `"video"`, `"audio"`, `"text"` |
| `timestamp` | `DateTime` | Exact timestamp when the log event was recorded. | `2026-09-03 10:30:15.123` |

---

### Network & Performance Metrics

| Property | Type | Description | Example |
| :--- | :--- | :--- | :--- |
| `statusCode` | `int?` | HTTP response status code. | `200`, `206`, `404`, `500` |
| `bytesLoaded` | `int` | Total number of bytes downloaded. | `1572864` (bytes) |
| `formattedSize` | `String` | Human-readable byte size formatted as B, KB, or MB. | `"1.50 MB"`, `"450.2 KB"` |
| `durationMs` | `int` | Network transfer duration in milliseconds. | `145` (ms) |
| `formattedDuration`| `String` | Human-readable transfer duration. | `"145 ms"`, `"1.25 s"` |
| `serverAddress` | `String?` | IP address or hostname of the remote server. | `"192.0.2.1"` |

---

### Media & Stream Metadata

| Property | Type | Description | Example |
| :--- | :--- | :--- | :--- |
| `bitrate` | `int?` | Bitrate of the media track in bits per second (bps). | `2500000` |
| `formattedBitrate`| `String?` | Human-readable bitrate formatted as kbps or Mbps. | `"2.50 Mbps"`, `"850 kbps"` |
| `width` | `int?` | Video width in pixels (if available). | `1920` |
| `height` | `int?` | Video height in pixels (if available). | `1080` |
| `mediaStartTimeMs` | `int?` | Playback start timestamp of the media chunk in stream. | `12000` (ms) |
| `mediaEndTimeMs` | `int?` | Playback end timestamp of the media chunk in stream. | `18000` (ms) |
| `errorMessage` | `String?` | Error description if the request failed or was aborted. | `"HTTP 404 Not Found"` |
| `extra` | `Map<String, dynamic>?` | Raw dictionary/map received from native player layer. | `{ ... }` |

---

### Helper Getters

| Getter | Type | Description |
| :--- | :--- | :--- |
| `isHls` | `bool` | Returns `true` if the request is an HLS chunk (`.ts`, `.m4s`) or manifest (`.m3u8`). |
| `isMediaChunk` | `bool` | Returns `true` if the request is a video/audio media segment chunk. |
| `isSuccessful` | `bool` | Returns `true` if request completed without errors and status code is `2xx` or `3xx`. |

---

## 3. Supported Enums

### `BetterPlayerNetworkLogPhase`
- `start`: Request has started.
- `completed`: Request finished successfully.
- `canceled`: Request was canceled / aborted before completion.
- `error`: Request encountered a network or HTTP error.

### `BetterPlayerNetworkDataType`
- `manifest`: Master playlist or media variant playlist (`.m3u8`, `.mpd`).
- `mediaSegment`: Audio/video chunk segment (`.ts`, `.m4s`, `fmp4`, `.mp4`).
- `initialization`: Initialization chunk header (`init.mp4`, `init.m4s`).
- `drmKey`: Encryption key or DRM license exchange (`.key`, Widevine, FairPlay).
- `subtitles`: External or muxed subtitle segment (`.vtt`, `.srt`).
- `unknown`: General or unclassified network load.

---

## 4. Converting to / from JSON

You can serialize or export logs to JSON:

```dart
// Convert single log to map
Map<String, dynamic> logMap = log.toMap();

// Convert list of logs to formatted JSON string
String jsonReport = jsonEncode(logs.map((l) => l.toMap()).toList());

// Create log from native map
BetterPlayerNetworkLog parsedLog = BetterPlayerNetworkLog.fromMap(logMap);
```
