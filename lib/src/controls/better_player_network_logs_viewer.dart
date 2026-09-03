import 'dart:async';
import 'dart:convert';
import 'package:better_player/better_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Filter category for the network logs view.
enum BetterPlayerNetworkLogFilter {
  all,
  chunks,
  manifests,
  errors,
}

/// A developer-friendly Network Inspector widget that displays real-time
/// video chunk and network request logs (like the browser DevTools Network tab).
class BetterPlayerNetworkLogsViewer extends StatefulWidget {
  /// The [BetterPlayerController] instance to monitor.
  final BetterPlayerController? controller;

  /// Optional custom stream of logs if not using a controller directly.
  final Stream<BetterPlayerNetworkLog>? customLogStream;

  /// Maximum number of logs to keep in memory (defaults to 500).
  final int maxLogs;

  /// Whether to show the top search and filter header bar.
  final bool showHeader;

  /// Whether to enable dark mode styling by default (if null, uses theme).
  final bool? isDarkMode;

  const BetterPlayerNetworkLogsViewer({
    Key? key,
    this.controller,
    this.customLogStream,
    this.maxLogs = 500,
    this.showHeader = true,
    this.isDarkMode,
  }) : super(key: key);

  /// Helper to show this network viewer in a modal bottom sheet.
  static Future<void> showModal(
    BuildContext context, {
    required BetterPlayerController controller,
    int maxLogs = 500,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: BetterPlayerNetworkLogsViewer(
                  controller: controller,
                  maxLogs: maxLogs,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  State<BetterPlayerNetworkLogsViewer> createState() =>
      _BetterPlayerNetworkLogsViewerState();
}

class _BetterPlayerNetworkLogsViewerState
    extends State<BetterPlayerNetworkLogsViewer> {
  final List<BetterPlayerNetworkLog> _logs = [];
  StreamSubscription<BetterPlayerNetworkLog>? _subscription;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  BetterPlayerNetworkLogFilter _selectedFilter =
      BetterPlayerNetworkLogFilter.all;
  String _searchQuery = '';
  bool _autoScroll = true;
  bool _isPaused = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
    _listenToLogs();
  }

  @override
  void didUpdateWidget(covariant BetterPlayerNetworkLogsViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.customLogStream != widget.customLogStream) {
      _subscription?.cancel();
      _listenToLogs();
    }
  }

  void _listenToLogs() {
    final stream =
        widget.customLogStream ?? widget.controller?.networkLogStream;
    if (stream != null) {
      _subscription = stream.listen((log) {
        if (_isPaused) return;
        if (!mounted) return;
        setState(() {
          _logs.add(log);
          if (_logs.length > widget.maxLogs) {
            _logs.removeAt(0);
          }
        });
        if (_autoScroll && _scrollController.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<BetterPlayerNetworkLog> get _filteredLogs {
    return _logs.where((log) {
      // Category filter
      switch (_selectedFilter) {
        case BetterPlayerNetworkLogFilter.chunks:
          if (!log.isMediaChunk) return false;
          break;
        case BetterPlayerNetworkLogFilter.manifests:
          if (log.dataType != BetterPlayerNetworkDataType.manifest &&
              !log.url.contains('.m3u8') &&
              !log.url.contains('.mpd')) {
            return false;
          }
          break;
        case BetterPlayerNetworkLogFilter.errors:
          if (log.isSuccessful) return false;
          break;
        case BetterPlayerNetworkLogFilter.all:
        default:
          break;
      }

      // Search query
      if (_searchQuery.isNotEmpty) {
        final matchesUrl = log.url.toLowerCase().contains(_searchQuery);
        final matchesFile = log.fileName.toLowerCase().contains(_searchQuery);
        final matchesType = log.dataType.name.toLowerCase().contains(_searchQuery);
        if (!matchesUrl && !matchesFile && !matchesType) return false;
      }

      return true;
    }).toList();
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  void _copyAllLogs() {
    final jsonList = _logs.map((e) => e.toMap()).toList();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(jsonList);
    Clipboard.setData(ClipboardData(text: jsonStr));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${_logs.length} network logs to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredLogs;
    final totalBytes = _logs.fold<int>(0, (sum, log) => sum + log.bytesLoaded);
    final totalBytesStr = BetterPlayerNetworkLog(
      id: '',
      url: '',
      phase: BetterPlayerNetworkLogPhase.completed,
      timestamp: DateTime.now(),
      bytesLoaded: totalBytes,
    ).formattedSize;

    return Column(
      children: [
        if (widget.showHeader) ...[
          _buildHeaderBar(totalBytesStr),
          _buildFilterBar(),
        ],
        const Divider(height: 1),
        _buildTableHeaders(),
        const Divider(height: 1),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState()
              : ListView.separated(
                  controller: _scrollController,
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, idx) => _buildLogRow(filtered[idx]),
                ),
        ),
      ],
    );
  }

  Widget _buildHeaderBar(String totalBytesStr) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.network_check_rounded, size: 20, color: Colors.blueAccent),
          const SizedBox(width: 8),
          const Text(
            'Network Logs',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${_logs.length} reqs | $totalBytesStr',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.blueAccent,
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              size: 20,
              color: _isPaused ? Colors.orange : Colors.grey,
            ),
            tooltip: _isPaused ? 'Resume logging' : 'Pause logging',
            onPressed: () {
              setState(() {
                _isPaused = !_isPaused;
              });
            },
          ),
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.arrow_downward_rounded : Icons.vertical_align_bottom_rounded,
              size: 20,
              color: _autoScroll ? Colors.blueAccent : Colors.grey,
            ),
            tooltip: 'Auto-scroll',
            onPressed: () {
              setState(() {
                _autoScroll = !_autoScroll;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: 'Copy all logs (JSON)',
            onPressed: _logs.isNotEmpty ? _copyAllLogs : null,
          ),
          IconButton(
            icon: const Icon(Icons.block_rounded, size: 18),
            tooltip: 'Clear logs',
            onPressed: _logs.isNotEmpty ? _clearLogs : null,
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Filter URL or type...',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () => _searchController.clear(),
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.withOpacity(0.3)),
                  ),
                  filled: true,
                  fillColor: Theme.of(context).cardColor.withOpacity(0.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildFilterChip('All', BetterPlayerNetworkLogFilter.all),
          const SizedBox(width: 4),
          _buildFilterChip('Chunks', BetterPlayerNetworkLogFilter.chunks),
          const SizedBox(width: 4),
          _buildFilterChip('Manifests', BetterPlayerNetworkLogFilter.manifests),
          const SizedBox(width: 4),
          _buildFilterChip('Errors', BetterPlayerNetworkLogFilter.errors),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, BetterPlayerNetworkLogFilter filter) {
    final isSelected = _selectedFilter == filter;
    return InkWell(
      onTap: () {
        setState(() {
          _selectedFilter = filter;
        });
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blueAccent
              : Theme.of(context).cardColor.withOpacity(0.6),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : null,
          ),
        ),
      ),
    );
  }

  Widget _buildTableHeaders() {
    return Container(
      color: Theme.of(context).cardColor.withOpacity(0.4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: const [
          SizedBox(
            width: 45,
            child: Text(
              'Status',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(width: 6),
          SizedBox(
            width: 60,
            child: Text(
              'Type',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Name / URL',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(
            width: 65,
            child: Text(
              'Size',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(width: 8),
          SizedBox(
            width: 55,
            child: Text(
              'Time',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogRow(BetterPlayerNetworkLog log) {
    final isSuccess = log.isSuccessful;
    final isError = log.phase == BetterPlayerNetworkLogPhase.error || !isSuccess;
    final isPending = log.phase == BetterPlayerNetworkLogPhase.start;

    final Color statusColor;
    final String statusText;
    if (isPending) {
      statusColor = Colors.blue;
      statusText = '...';
    } else if (isError) {
      statusColor = Colors.red;
      statusText = log.statusCode?.toString() ?? 'ERR';
    } else {
      statusColor = Colors.green;
      statusText = log.statusCode?.toString() ?? '200';
    }

    return InkWell(
      onTap: () => _showLogDetails(log),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            // Status Badge
            Container(
              width: 45,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: statusColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Data Type Pill
            SizedBox(
              width: 60,
              child: Text(
                _dataTypeShort(log),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: _dataTypeColor(log),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // URL / Name
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    log.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    log.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.withOpacity(0.8),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            // Size
            SizedBox(
              width: 65,
              child: Text(
                log.formattedSize,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11),
              ),
            ),
            const SizedBox(width: 8),
            // Time
            SizedBox(
              width: 55,
              child: Text(
                log.formattedDuration,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _dataTypeShort(BetterPlayerNetworkLog log) {
    switch (log.dataType) {
      case BetterPlayerNetworkDataType.manifest:
        return 'Manifest';
      case BetterPlayerNetworkDataType.mediaSegment:
        return 'Segment';
      case BetterPlayerNetworkDataType.initialization:
        return 'Init';
      case BetterPlayerNetworkDataType.drmKey:
        return 'Key';
      case BetterPlayerNetworkDataType.subtitles:
        return 'Subtitles';
      case BetterPlayerNetworkDataType.unknown:
      default:
        if (log.url.contains('.ts')) return 'TS Chunk';
        if (log.url.contains('.m4s')) return 'M4S Chunk';
        if (log.url.contains('.m3u8')) return 'M3U8';
        return 'Media';
    }
  }

  Color _dataTypeColor(BetterPlayerNetworkLog log) {
    switch (log.dataType) {
      case BetterPlayerNetworkDataType.manifest:
        return Colors.purpleAccent;
      case BetterPlayerNetworkDataType.mediaSegment:
        return Colors.teal;
      case BetterPlayerNetworkDataType.initialization:
        return Colors.indigoAccent;
      case BetterPlayerNetworkDataType.drmKey:
        return Colors.amber;
      case BetterPlayerNetworkDataType.subtitles:
        return Colors.deepOrangeAccent;
      case BetterPlayerNetworkDataType.unknown:
      default:
        return Colors.blueGrey;
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_tethering_off_rounded, size: 48, color: Colors.grey.withOpacity(0.5)),
          const SizedBox(height: 8),
          Text(
            _logs.isEmpty
                ? 'No network requests captured yet.\nPlay a video or HLS stream to see chunk logs.'
                : 'No requests match the current filter.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.withOpacity(0.8), fontSize: 13),
          ),
        ],
      ),
    );
  }

  void _showLogDetails(BetterPlayerNetworkLog log) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      log.fileName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy full URL',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: log.url));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('URL copied to clipboard')),
                      );
                    },
                  ),
                ],
              ),
              const Divider(),
              _buildDetailItem('Full URL', log.url),
              _buildDetailItem('Method', log.httpMethod),
              _buildDetailItem('Phase', log.phase.name),
              _buildDetailItem('Data Type', log.dataType.name),
              if (log.trackType != null) _buildDetailItem('Track Type', log.trackType!),
              _buildDetailItem('Status Code', log.statusCode?.toString() ?? 'N/A'),
              _buildDetailItem('Bytes Loaded', '${log.bytesLoaded} bytes (${log.formattedSize})'),
              _buildDetailItem('Duration', '${log.durationMs} ms'),
              if (log.formattedBitrate != null) _buildDetailItem('Bitrate', log.formattedBitrate!),
              if (log.width != null && log.height != null)
                _buildDetailItem('Resolution', '${log.width} x ${log.height}'),
              if (log.serverAddress != null) _buildDetailItem('Server IP', log.serverAddress!),
              if (log.mediaStartTimeMs != null && log.mediaEndTimeMs != null)
                _buildDetailItem('Media Segment Range',
                    '${log.mediaStartTimeMs}ms -> ${log.mediaEndTimeMs}ms'),
              if (log.errorMessage != null)
                _buildDetailItem('Error', log.errorMessage!, isError: true),
              _buildDetailItem('Timestamp', log.timestamp.toIso8601String()),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () {
                  final jsonStr = const JsonEncoder.withIndent('  ').convert(log.toMap());
                  Clipboard.setData(ClipboardData(text: jsonStr));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Log details copied as JSON')),
                  );
                },
                icon: const Icon(Icons.copy_all, size: 16),
                label: const Text('Copy JSON Details'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailItem(String label, String value, {bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.grey.withOpacity(0.9),
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(
              fontSize: 13,
              color: isError ? Colors.red : null,
            ),
          ),
        ],
      ),
    );
  }
}
