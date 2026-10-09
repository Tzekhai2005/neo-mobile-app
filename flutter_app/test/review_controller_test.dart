import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/review/review_controller.dart';
import 'package:neo_companion/review/review_models.dart';

const mini = 'test/fixtures/mini_recording'; // one hour, 5 events (one patient press)
const demo = 'test/fixtures/demo_3day'; // three days, 119 events

class _NoShare implements FileSharer {
  @override
  Future<void> share(List<File> files, {String? subject}) async {}
}

void main() {
  late Directory dir;
  final opened = <AppServices>[];

  setUp(() => dir = Directory.systemTemp.createTempSync('neo_review_'));
  tearDown(() async {
    for (final s in opened) {
      await s.dispose();
    }
    opened.clear();
    dir.deleteSync(recursive: true);
  });

  AppServices services(String dataset, {Directory? at, bool storage = true}) {
    final s = AppServices(
      client: NeoClient(),
      dataDir: storage ? (at ?? dir) : null,
      reader: DirectoryDatasetReader(dataset),
      sharer: _NoShare(),
    );
    opened.add(s);
    return s;
  }

  Future<ReviewController> loaded(String dataset, {Directory? at}) async {
    final c = ReviewController(services(dataset, at: at));
    await c.load();
    return c;
  }

  group('loading', () {
    test('is ready with the recording and its events', () async {
      final c = await loaded(mini);
      expect(c.loadState, ReviewLoad.ready);
      expect(c.events.length, 5);
      expect(c.info.durationSec, 3600);
      expect(c.counts.total, 5);
    });

    test('says plainly when the phone has no storage for decisions', () async {
      final c = ReviewController(services(mini, storage: false));
      await c.load();
      expect(c.loadState, ReviewLoad.unavailable);
      expect(c.loadMessage, contains('no app storage'));
    });

    test('says plainly when the recording cannot be opened', () async {
      final c = ReviewController(services('test/fixtures/does_not_exist'));
      await c.load();
      expect(c.loadState, ReviewLoad.failed);
      expect(c.loadMessage, contains('could not be opened'));
    });

    test('starts out loading and tells its listeners when it is done', () async {
      final c = ReviewController(services(mini));
      expect(c.loadState, ReviewLoad.loading);
      var told = 0;
      c.addListener(() => told++);
      await c.load();
      expect(told, greaterThanOrEqualTo(1));
    });
  });

  group('days', () {
    test('a three-day recording opens on day one, one day wide', () async {
      final c = await loaded(demo);
      expect(c.dayCount, 3);
      expect(c.mode, RangeMode.oneDay);
      expect(c.bounds.startSec, 0);
      expect(c.bounds.endSec, 86400);
      expect(c.rangeLabel, 'Mon 5 Oct');
    });

    test('the arrows move a day at a time and stop at the ends', () async {
      final c = await loaded(demo);
      expect(c.canPage(-1), isFalse);
      expect(c.canPage(1), isTrue);
      c.pageDays(1);
      expect(c.bounds.startSec, 86400);
      expect(c.rangeLabel, 'Tue 6 Oct');
      c.pageDays(1);
      expect(c.canPage(1), isFalse);
      c.pageDays(1); // ignored
      expect(c.firstDay, 2);
      c.pageDays(-1);
      expect(c.firstDay, 1);
    });

    test('three days on a three-day recording is all of it, with nowhere to page', () async {
      final c = await loaded(demo);
      c.setMode(RangeMode.threeDays);
      expect(c.bounds.startSec, 0);
      expect(c.bounds.endSec, 259200);
      expect(c.canPage(1), isFalse);
      expect(c.rangeLabel, 'Mon 5 Oct to Wed 7 Oct');
    });

    test('switching back to one day keeps the first day, and never goes past the end', () async {
      final c = await loaded(demo);
      c.pageDays(1);
      c.pageDays(1); // day three
      c.setMode(RangeMode.threeDays);
      expect(c.firstDay, 0, reason: 'three days must fit inside three');
      c.setMode(RangeMode.oneDay);
      expect(c.windowDays, 1);
    });

    test('a recording shorter than a day is one range whatever the switch says', () async {
      final c = await loaded(mini);
      expect(c.dayCount, 1);
      c.setMode(RangeMode.threeDays);
      expect(c.windowDays, 1);
      expect(c.bounds.endSec, 3600, reason: 'only as long as the recording');
      expect(c.canPage(1), isFalse);
    });

    test('paging resets the zoom', () async {
      final c = await loaded(demo);
      c.zoom(8, 0.5);
      expect(c.isZoomed, isTrue);
      c.pageDays(1);
      expect(c.isZoomed, isFalse);
    });
  });

  group('the list follows the days on show', () {
    test('only that day\'s events, and all of them across the days', () async {
      final c = await loaded(demo);
      final rate = c.info.eegRateHz;
      int inDay(int d) => c.events.where((e) => e.event.startSec(rate) >= d * 86400 && e.event.startSec(rate) < (d + 1) * 86400).length;
      var total = 0;
      for (var d = 0; d < 3; d++) {
        if (d > 0) c.pageDays(1);
        expect(c.lists.ordered.length, inDay(d), reason: 'day ${d + 1}');
        total += c.lists.ordered.length;
      }
      expect(total, 119);
      c.setMode(RangeMode.threeDays);
      expect(c.lists.ordered.length, 119);
    });

    test('markers first, then candidates by score', () async {
      final c = await loaded(demo);
      c.setMode(RangeMode.threeDays);
      final l = c.lists;
      expect(l.markers.length, 9);
      expect(l.candidates.length, 110);
      final scores = [for (final e in l.candidates) e.event.confidence!];
      expect([...scores]..sort((a, b) => b.compareTo(a)), scores);
    });

    test('the progress counts every event, not just the ones on show', () async {
      final c = await loaded(demo);
      expect(c.counts.total, 119);
      c.pageDays(1);
      expect(c.counts.total, 119);
    });

    test('a filter narrows the list but not the progress', () async {
      final c = await loaded(mini);
      c.select(c.lists.candidates.first.event.id);
      await c.confirm();
      c.setFilter(ReviewFilter.confirmed);
      expect(c.lists.ordered.length, 1);
      expect(c.counts.total, 5);
      c.setFilter(ReviewFilter.unreviewed);
      expect(c.lists.ordered.length, 4);
    });
  });

  group('zoom and pan', () {
    test('zooming in narrows the view around the point asked for', () async {
      final c = await loaded(demo);
      c.zoom(4, 0.5);
      expect(c.visible.lengthSec, closeTo(21600, 1e-6));
      expect(c.visible.startSec + c.visible.lengthSec / 2, closeTo(43200, 1e-6), reason: 'the middle stayed put');
    });

    test('the point under the fingers stays under the fingers', () async {
      final c = await loaded(demo);
      final before = c.visible.startSec + 0.25 * c.visible.lengthSec;
      c.zoom(4, 0.25);
      expect(c.visible.startSec + 0.25 * c.visible.lengthSec, closeTo(before, 1e-6));
    });

    test('it cannot zoom out past the days on show, or in past ten minutes', () async {
      final c = await loaded(demo);
      c.zoom(0.1, 0.5);
      expect(c.visible.lengthSec, 86400);
      c.zoom(100000, 0.5);
      expect(c.visible.lengthSec, ReviewController.minViewSec);
    });

    test('it cannot slide off either end', () async {
      final c = await loaded(demo);
      c.zoom(4, 0.5);
      c.pan(-1e9);
      expect(c.visible.startSec, 0);
      c.pan(1e9);
      expect(c.visible.endSec, 86400);
      expect(c.visible.lengthSec, closeTo(21600, 1e-6));
    });

    test('a zoom on a one-hour recording stops at the recording\'s length', () async {
      final c = await loaded(mini);
      c.zoom(1000, 0.5);
      expect(c.visible.lengthSec, ReviewController.minViewSec);
      c.resetZoom();
      expect(c.visible.lengthSec, 3600);
    });

    test('nonsense zoom factors are ignored', () async {
      final c = await loaded(demo);
      c.zoom(0, 0.5);
      c.zoom(-2, 0.5);
      c.zoom(double.nan, 0.5);
      expect(c.visible.lengthSec, 86400);
    });

    test('an unchanged view does not disturb listeners', () async {
      final c = await loaded(demo);
      var told = 0;
      c.addListener(() => told++);
      c.pan(100); // already the whole day: nowhere to go
      expect(told, 0);
    });

    test('a moment off to the side is brought into view, a moment in view is left alone', () async {
      final c = await loaded(demo);
      c.zoom(8, 0.0); // the first three hours
      final before = c.visible.startSec;
      c.ensureVisible(1000);
      expect(c.visible.startSec, before);
      c.ensureVisible(70000);
      expect(c.visible.contains(70000), isTrue);
    });
  });

  group('selecting and walking through events', () {
    test('selecting brings that event into view', () async {
      final c = await loaded(demo);
      c.zoom(24, 0.0); // the first hour
      final late = c.events.firstWhere((e) => e.event.startSec(250) > 50000 && e.event.startSec(250) < 86000);
      c.select(late.event.id);
      expect(c.visible.contains(late.event.startSec(250)), isTrue);
      expect(c.selected!.event.id, late.event.id);
    });

    test('an unknown id selects nothing', () async {
      final c = await loaded(mini);
      c.select('nope');
      expect(c.selectedId, isNull);
    });

    test('next and previous walk the list in order, and stop at its ends', () async {
      final c = await loaded(mini);
      final order = [for (final e in c.lists.ordered) e.event.id];
      c.next();
      expect(c.selectedId, order.first, reason: 'with nothing selected, Next starts at the top');
      expect(c.position, 1);
      c.next();
      expect(c.selectedId, order[1]);
      c.previous();
      expect(c.selectedId, order.first);
      c.previous();
      expect(c.selectedId, order.first);
      for (var i = 0; i < 10; i++) {
        c.next();
      }
      expect(c.selectedId, order.last);
      expect(c.position, order.length);
      expect(c.positionCount, order.length);
    });

    test('with nothing selected Previous starts at the bottom', () async {
      final c = await loaded(mini);
      c.previous();
      expect(c.selectedId, c.lists.ordered.last.event.id);
    });

    test('the walk follows the filter', () async {
      final c = await loaded(mini);
      c.select(c.lists.candidates.first.event.id);
      await c.confirm();
      c.setFilter(ReviewFilter.confirmed);
      expect(c.positionCount, 1);
      c.next();
      expect(c.selectedId, c.lists.ordered.single.event.id);
    });

    test('an event a filter hides has no position, but stays selected', () async {
      final c = await loaded(mini);
      c.select(c.lists.candidates.first.event.id);
      c.setFilter(ReviewFilter.confirmed);
      expect(c.position, isNull);
      expect(c.selected, isNotNull);
    });

    test('clearing the selection', () async {
      final c = await loaded(mini);
      c.next();
      c.clearSelection();
      expect(c.selected, isNull);
    });
  });

  group('decisions', () {
    test('confirm and dismiss show at once, and are what is saved', () async {
      final c = await loaded(mini);
      final id = c.lists.candidates.first.event.id;
      c.select(id);
      await c.confirm();
      expect(c.selected!.status, ReviewStatus.confirmed);
      await c.dismiss();
      expect(c.selected!.status, ReviewStatus.dismissed);
      expect(c.counts.dismissed, 1);
      expect(c.counts.reviewed, 1);
    });

    test('undo goes back to unreviewed', () async {
      final c = await loaded(mini);
      c.select(c.lists.candidates.first.event.id);
      await c.confirm();
      await c.undo();
      expect(c.selected!.status, ReviewStatus.candidate);
      expect(c.counts.reviewed, 0);
    });

    test('a note is kept through a change of mind, and cleared by a blank one', () async {
      final c = await loaded(mini);
      c.select(c.lists.candidates.first.event.id);
      await c.setNote('carer saw a head turn');
      await c.confirm();
      expect(c.selected!.note, 'carer saw a head turn');
      await c.undo();
      expect(c.selected!.note, 'carer saw a head turn', reason: 'undo keeps the note');
      await c.setNote('   ');
      expect(c.selected!.note, isNull);
    });

    test('decisions survive closing the app', () async {
      final first = await loaded(mini);
      final id = first.lists.candidates.first.event.id;
      first.select(id);
      await first.confirm();
      await first.setNote('keep this');

      final again = await loaded(mini); // a new run on the same folder
      again.select(id);
      expect(again.selected!.status, ReviewStatus.confirmed);
      expect(again.selected!.note, 'keep this');
    });

    test('quick one after another cannot cross', () async {
      final c = await loaded(mini);
      c.select(c.lists.candidates.first.event.id);
      final a = c.confirm();
      final b = c.setNote('quick');
      final d = c.dismiss();
      await Future.wait([a, b, d]);
      expect(c.selected!.status, ReviewStatus.dismissed);
      expect(c.selected!.note, 'quick');
    });

    test('a note goes to the event it was typed on, even after the reviewer has moved on', () async {
      final c = await loaded(mini);
      final first = c.lists.candidates.first.event.id;
      final second = c.lists.candidates[1].event.id;
      c.select(first);
      final pending = c.setNoteFor(first, 'typed on the first');
      c.select(second);
      await pending;
      expect(c.events.firstWhere((e) => e.event.id == first).note, 'typed on the first');
      expect(c.events.firstWhere((e) => e.event.id == second).note, isNull);
    });

    test('a save that finishes after the page is gone does not touch it', () async {
      final c = await loaded(mini);
      c.select(c.lists.candidates.first.event.id);
      final pending = c.confirm();
      c.dispose();
      await pending; // must not throw
    });

    test('a decision with nothing selected does nothing', () async {
      final c = await loaded(mini);
      await c.confirm();
      await c.setNote('x');
      expect(c.counts.reviewed, 0);
    });

    test('a patient marker can be decided about too', () async {
      final c = await loaded(mini);
      c.select(c.lists.markers.single.event.id);
      await c.confirm();
      expect(c.selected!.status, ReviewStatus.confirmed);
    });

    test('a failure to save is said, and what is shown is what is saved', () async {
      // a folder where the decisions file should be: the write cannot succeed
      Directory('${dir.path}/review_decisions.json').createSync();
      final c = await loaded(mini);
      c.select(c.lists.candidates.first.event.id);
      await c.confirm();
      expect(c.saveError, contains('could not be saved'));
      expect(c.selected!.status, ReviewStatus.candidate, reason: 'it did not pretend to save');
    });

    test('listeners hear about every change', () async {
      final c = await loaded(mini);
      c.select(c.lists.candidates.first.event.id);
      var told = 0;
      c.addListener(() => told++);
      await c.confirm();
      expect(told, greaterThanOrEqualTo(1));
    });
  });

  group('what the timeline draws', () {
    test('marks for the automatic events, a row for the patient markers, labels and poor stretches', () async {
      final c = await loaded(demo);
      c.setMode(RangeMode.threeDays);
      final s = c.snapshotFor(360);
      final autos = s.bars.fold<int>(0, (n, k) => n + k.events.length);
      final marks = s.markers.fold<int>(0, (n, k) => n + k.events.length);
      expect(autos, 110);
      expect(marks, 9);
      expect(s.ticks, isNotEmpty);
      expect(s.visible.lengthSec, 259200);
      expect(s.overview.count, lessThanOrEqualTo(360));
      expect(s.poor, isNotEmpty, reason: 'the demo has stretches of poor signal');
    });

    test('zoomed in, only what is in view, and fewer events share a mark', () async {
      final c = await loaded(demo);
      c.setMode(RangeMode.threeDays);
      final wide = c.snapshotFor(360);
      c.zoom(30, 0.5);
      final tight = c.snapshotFor(360);
      expect(tight.bars.fold<int>(0, (n, k) => n + k.events.length), lessThan(110));
      expect(tight.bars.length / (tight.bars.fold<int>(0, (n, k) => n + k.events.length) + 1),
          greaterThanOrEqualTo(wide.bars.length / 111) , reason: 'zooming in separates events');
    });

    test('is the same object until something changes', () async {
      final c = await loaded(demo);
      final a = c.snapshotFor(360);
      expect(identical(c.snapshotFor(360), a), isTrue);
      expect(identical(c.snapshotFor(400), a), isFalse, reason: 'a different width is a different drawing');
    });

    test('is redrawn after a decision, so a confirmed event changes colour', () async {
      final c = await loaded(mini);
      final before = c.snapshotFor(300);
      c.select(c.lists.candidates.first.event.id);
      await c.confirm();
      final after = c.snapshotFor(300);
      expect(identical(before, after), isFalse);
      final id = c.selectedId!;
      expect(after.bars.expand((k) => k.events).firstWhere((e) => e.event.id == id).status, ReviewStatus.confirmed);
    });
  });

  group('the signal around an event', () {
    test('loads the stored window, and does not load it twice for the same event', () async {
      final c = await loaded(mini);
      final id = c.lists.candidates.first.event.id;
      final a = c.windowFor(id);
      expect(identical(c.windowFor(id), a), isTrue);
      final w = await a;
      expect(w.eventId, id);
      expect(w.eeg.length, 2);
    });

    test('an unknown event is a failure that is not remembered', () async {
      final c = await loaded(mini);
      await expectLater(c.windowFor('nope'), throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      await expectLater(c.windowFor('nope'), throwsA(anything));
    });

    test('keeps only the last few', () async {
      final c = await loaded(demo);
      final ids = [for (final e in c.events.take(8)) e.event.id];
      final first = c.windowFor(ids.first);
      for (final id in ids.skip(1)) {
        c.windowFor(id);
      }
      expect(identical(c.windowFor(ids.first), first), isFalse, reason: 'the oldest was let go');
    });
  });
}
