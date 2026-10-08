import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/ui/format.dart';

void main() {
  test('every link state has a plain label', () {
    expect(linkLabel(LinkState.searching), 'Searching for the device');
    expect(linkLabel(LinkState.connecting), 'Connecting');
    expect(linkLabel(LinkState.connected), 'Connected');
    expect(linkLabel(LinkState.stalled), 'No data');
  });

  group('what the device has not reported is a dash, never a number', () {
    test('battery', () {
      expect(batteryText(const DeviceStatus()), '–');
      expect(batteryText(const DeviceStatus(batteryPct: 48)), '48 %');
      expect(batteryText(const DeviceStatus(batteryPct: 0)), '0 %', reason: 'a real 0 is shown as 0');
      expect(batteryText(const DeviceStatus(batteryPct: 80, charging: true)), '80 %, charging');
    });

    test('Wi-Fi strength', () {
      expect(wifiText(null), '–');
      expect(wifiText(-52), '−52 dBm');
    });

    test('channels and rate need both', () {
      expect(streamText(const DeviceStatus()), '–');
      expect(streamText(const DeviceStatus(eegChannels: 2)), '–');
      expect(streamText(const DeviceStatus(eegChannels: 2, eegRateHz: 250)), '2 ch · 250 Hz');
      expect(streamText(const DeviceStatus(eegChannels: 4, eegRateHz: 500)), '4 ch · 500 Hz');
    });

    test('electrode contact', () {
      expect(contactText(null), '–');
      expect(contactText(false), 'Good');
      expect(contactText(true), 'Check the electrodes');
    });

    test('percentages', () {
      expect(percentText(null), '–');
      expect(percentText(0), '0.0 %');
      expect(percentText(2.345), '2.3 %');
    });
  });

  test('plurals', () {
    expect(plural(1, 'event'), '1 event');
    expect(plural(0, 'event'), '0 events');
    expect(plural(3, 'day'), '3 days');
    expect(plural(2, 'box', 'boxes'), '2 boxes');
  });

  test('durations read in the biggest sensible unit', () {
    expect(durationText(3 * 86400), '3 days');
    expect(durationText(86400), '1 day');
    expect(durationText(5 * 3600), '5 hours');
    expect(durationText(3600), '1 hour');
    expect(durationText(40 * 60), '40 minutes');
    expect(durationText(60), '1 minute');
  });

  test('sizes', () {
    expect(sizeText(512), '512 bytes');
    expect(sizeText(2048), '2 KB');
    expect(sizeText(5 * (1 << 20)), '5.0 MB');
  });
}
