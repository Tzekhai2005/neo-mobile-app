import '../device/device_status.dart';

// Plain-language text for what the device and a recording report. A value the
// device has not reported is "–", never a made-up number.

const String unknownText = '–';

String linkLabel(LinkState link) => switch (link) {
      LinkState.searching => 'Searching for the device',
      LinkState.connecting => 'Connecting',
      LinkState.connected => 'Connected',
      LinkState.stalled => 'No data',
    };

/// What to do when no device is found.
const String searchingHint = 'Switch the Neo on and make sure your phone is on the same Wi-Fi.';

String batteryText(DeviceStatus s) {
  if (s.batteryPct == null) return unknownText;
  return s.charging == true ? '${s.batteryPct} %, charging' : '${s.batteryPct} %';
}

String wifiText(int? rssiDbm) => rssiDbm == null ? unknownText : '−${rssiDbm.abs()} dBm';

/// "2 ch · 250 Hz".
String streamText(DeviceStatus s) {
  if (s.eegChannels == null || s.eegRateHz == null) return unknownText;
  return '${s.eegChannels} ch · ${s.eegRateHz} Hz';
}

String contactText(bool? leadOff) => switch (leadOff) {
      null => unknownText,
      true => 'Check the electrodes',
      false => 'Good',
    };

String percentText(double? percent) => percent == null ? unknownText : '${percent.toStringAsFixed(1)} %';

String plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// "3 days", "1 day", "5 hours", "40 minutes".
String durationText(int seconds) {
  if (seconds >= 86400) return plural((seconds / 86400).round(), 'day');
  if (seconds >= 3600) return plural((seconds / 3600).round(), 'hour');
  return plural((seconds / 60).round(), 'minute');
}

String sizeText(int bytes) {
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).round()} KB';
  return '$bytes bytes';
}

/// "14:32:10", from a local time.
String clockText(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

/// "Good morning", "Good afternoon" or "Good evening", from a local time.
String greetingFor(DateTime local) => local.hour < 12
    ? 'Good morning'
    : local.hour < 18
        ? 'Good afternoon'
        : 'Good evening';

/// The one line under the greeting: what the device is doing, said plainly.
String deviceHeadline(LinkState link) => switch (link) {
      LinkState.connected => 'Your device is connected.',
      LinkState.connecting => 'Connecting to your device…',
      LinkState.stalled => 'Your device is connected but not sending data.',
      LinkState.searching => 'Looking for your device…',
    };
