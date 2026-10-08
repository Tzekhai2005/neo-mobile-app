import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../device/device_status.dart';
import '../../live/live_signal_buffer.dart';
import '../theme/app_theme.dart';
import 'live_trace.dart';

/// The main card on the start page: the live view, with a small live trace in
/// it while the device streams.
class LiveDataCard extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;
  final LiveSignalBuffer buffer;
  final VoidCallback onTap;

  const LiveDataCard({super.key, required this.status, required this.buffer, required this.onTap});

  static (String, Color) stateOf(LinkState l) => switch (l) {
        LinkState.connected => ('Streaming', const Color(0xFF6FE3A8)),
        LinkState.stalled => ('No data', const Color(0xFFFFC857)),
        LinkState.connecting => ('Connecting', const Color(0xFFFFC857)),
        LinkState.searching => ('Waiting for the device', const Color(0xFFB6C2D9)),
      };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.navy,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 158,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ValueListenableBuilder<DeviceStatus>(
                valueListenable: status,
                builder: (context, s, _) {
                  final (label, dot) = stateOf(s.link);
                  return Row(children: [
                    const Text('Live data',
                        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: AppColors.onNavy)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(width: 9, height: 9, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                          const SizedBox(width: 7),
                          Flexible(
                            child: Text(label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: AppColors.onNavy)),
                          ),
                        ]),
                      ),
                    ),
                  ]);
                },
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: LiveTraceStrip(buffer: buffer, status: status, color: AppColors.onNavy),
                ),
              ),
              Text('Open the live view',
                  style: TextStyle(fontSize: 13, color: AppColors.onNavy.withValues(alpha: 0.8))),
            ]),
          ),
        ),
      ),
    );
  }
}
