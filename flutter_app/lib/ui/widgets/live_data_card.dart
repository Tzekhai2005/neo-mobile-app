import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../device/device_status.dart';
import '../../live/live_signal_buffer.dart';
import '../theme/app_theme.dart';
import 'live_trace.dart';

/// The live card on the start page: a small live trace while the device streams,
/// and the way into the Live tab.
class LiveDataCard extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;
  final LiveSignalBuffer buffer;
  final VoidCallback onTap;

  const LiveDataCard({super.key, required this.status, required this.buffer, required this.onTap});

  static (String, Color) stateOf(LinkState l) => switch (l) {
        LinkState.connected => ('Streaming', AppColors.success),
        LinkState.stalled => ('No data', AppColors.warning),
        LinkState.connecting => ('Connecting', AppColors.warning),
        LinkState.searching => ('Waiting for the device', AppColors.textMuted),
      };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 168,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ValueListenableBuilder<DeviceStatus>(
                valueListenable: status,
                builder: (context, s, _) {
                  final (label, dot) = stateOf(s.link);
                  return Row(children: [
                    const Flexible(
                      child: Text('Live brain activity',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
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
                                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
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
                  child: LiveTraceStrip(buffer: buffer, status: status, color: AppColors.accent),
                ),
              ),
              const Row(children: [
                Text('View live monitoring',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.accent)),
                SizedBox(width: 4),
                Icon(Icons.arrow_forward, size: 16, color: AppColors.accent),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
