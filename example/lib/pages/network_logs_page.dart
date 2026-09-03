import 'package:better_player/better_player.dart';
import 'package:example/constants.dart';
import 'package:flutter/material.dart';

class NetworkLogsPage extends StatefulWidget {
  @override
  _NetworkLogsPageState createState() => _NetworkLogsPageState();
}

class _NetworkLogsPageState extends State<NetworkLogsPage> {
  late BetterPlayerController _betterPlayerController;

  @override
  void initState() {
    super.initState();
    final betterPlayerConfiguration = const BetterPlayerConfiguration(
      aspectRatio: 16 / 9,
      fit: BoxFit.contain,
      autoPlay: true,
      looping: true,
    );

    // HLS Data Source with video/audio segments
    final dataSource = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      Constants.elephantDreamStreamUrl,
      useAsmsSubtitles: true,
      useAsmsTracks: true,
      useAsmsAudioTracks: true,
    );

    _betterPlayerController = BetterPlayerController(betterPlayerConfiguration);
    _betterPlayerController.setupDataSource(dataSource);
  }

  @override
  void dispose() {
    _betterPlayerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Network & Chunk Logger"),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: "Open Network Inspector Modal",
            onPressed: () {
              BetterPlayerNetworkLogsViewer.showModal(
                context,
                controller: _betterPlayerController,
              );
            },
          )
        ],
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: BetterPlayer(controller: _betterPlayerController),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.blueAccent.withOpacity(0.08),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16, color: Colors.blueAccent),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    "Network tab inspector below captures every HLS segment (.ts, .m4s), manifest (.m3u8), and key request in real-time.",
                    style: TextStyle(fontSize: 11, color: Colors.blueAccent),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: BetterPlayerNetworkLogsViewer(
              controller: _betterPlayerController,
            ),
          ),
        ],
      ),
    );
  }
}
