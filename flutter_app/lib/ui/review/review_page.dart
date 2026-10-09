import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../data/review_event.dart';
import '../../review/review_controller.dart';
import '../../review/review_models.dart';
import '../../review/timeline_model.dart';
import '../data/data_controls.dart';
import '../format.dart';
import '../theme/app_theme.dart';
import 'event_sheet.dart';
import 'review_timeline.dart';
import 'review_widgets.dart';

/// Go through the events a recording holds: a compressed timeline of the days, the
/// patient's button presses pinned apart from the candidates ranked by score, and for
/// any one of them its signal, a note, and Confirm or Dismiss.
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  ReviewController? _c;
  final ScrollController _scroll = ScrollController();
  String? _lastSelected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c == null) {
      _c = ReviewController(AppScope.of(context))..addListener(_onChanged);
      _c!.load();
    }
  }

  @override
  void dispose() {
    _c?.removeListener(_onChanged);
    _c?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// A new selection (from the timeline, or Next) scrolls the list to its row.
  void _onChanged() {
    final id = _c!.selectedId;
    if (id == _lastSelected) return;
    _lastSelected = id;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = GlobalObjectKey(id).currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.15, duration: const Duration(milliseconds: 250));
      } else if (_scroll.hasClients) {
        // Not built yet (far down a long list): get close, then settle on it.
        final i = _c!.lists.ordered.indexWhere((e) => e.event.id == id);
        if (i >= 0) _scroll.jumpTo((i * 66.0).clamp(0.0, _scroll.position.maxScrollExtent));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final later = GlobalObjectKey(id).currentContext;
          if (mounted && later != null) Scrollable.ensureVisible(later, alignment: 0.15);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _c!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => switch (c.loadState) {
        ReviewLoad.loading => const Center(child: CircularProgressIndicator()),
        ReviewLoad.unavailable ||
        ReviewLoad.failed =>
          _Message(text: c.loadMessage ?? '', icon: Icons.folder_off_outlined),
        ReviewLoad.ready => _Ready(controller: c, scroll: _scroll),
      },
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Message({required this.text, required this.icon});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Text(text,
                key: const ValueKey('review-message'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary)),
          ]),
        ),
      );
}

class _Ready extends StatelessWidget {
  final ReviewController controller;
  final ScrollController scroll;

  const _Ready({required this.controller, required this.scroll});

  String _when(ReviewEvent e) {
    final local = controller.info.localTimeAt(e.event.startSec(controller.info.eegRateHz));
    return controller.windowDays > 1 ? '${dateLabel(local)} · ${clockText(local).substring(0, 5)}' : clockText(local);
  }

  double _duration(ReviewEvent e) => e.event.durationSec(controller.info.eegRateHz);

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final lists = c.lists;
    final counts = c.counts;
    return Stack(children: [
      Positioned.fill(
        child: LayoutBuilder(builder: (context, box) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Header(controller: c),
              const SizedBox(height: 10),
              Row(children: [
                _RangeSwitch(controller: c),
                const Spacer(),
                if (!c.showsDailyBars)
                  PillButton(
                    key: const ValueKey('show-signal'),
                    label: 'Show signal',
                    selected: c.showSignal,
                    tooltip: c.showSignal
                        ? 'Hide the EEG and movement behind the marks'
                        : 'Show the EEG and movement behind the marks',
                    onTap: c.toggleShowSignal,
                  ),
              ]),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  key: const ValueKey('earlier'),
                  tooltip: 'Earlier',
                  onPressed: c.canPage(-1) ? () => c.pageDays(-1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(c.rangeLabel,
                    key: const ValueKey('range-label'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                IconButton(
                  key: const ValueKey('later'),
                  tooltip: 'Later',
                  onPressed: c.canPage(1) ? () => c.pageDays(1) : null,
                  icon: const Icon(Icons.chevron_right),
                ),
                if (c.isZoomed)
                  TextButton(
                      key: const ValueKey('reset-zoom'), onPressed: c.resetZoom, child: const Text('Reset zoom')),
              ]),
              if (c.showsDailyBars)
                DailyBars(controller: c)
              else
                ReviewTimeline(
                  controller: c,
                  onCluster: (cluster) async {
                    final id = await pickFromCluster(context, cluster, when: _when, duration: _duration);
                    if (id != null) c.select(id);
                  },
                ),
              const SizedBox(height: 12),
              CategoryTiles(counts: c.categoryCounts, selected: c.category, onTap: c.setCategory),
              if (c.hasActiveFilter) _ActiveFilters(controller: c),
              const SizedBox(height: 8),
              Expanded(
                child: lists.isEmpty
                    ? _EmptyList(hasEvents: counts.total > 0)
                    : ListView(
                        controller: scroll,
                        padding: EdgeInsets.only(bottom: c.selectedId == null ? 8 : box.maxHeight * 0.62),
                        children: [
                          if (lists.markers.isNotEmpty) ...[
                            _GroupHeader('Marked by you', lists.markers.length),
                            for (final e in lists.markers) _row(e),
                          ],
                          if (lists.candidates.isNotEmpty) ...[
                            _GroupHeader(
                                'Events, ${switch (c.sort) {
                                  ReviewSort.score => 'highest score first',
                                  ReviewSort.newest => 'newest first',
                                  ReviewSort.oldest => 'oldest first'
                                }}',
                                lists.candidates.length),
                            for (final e in lists.candidates) _row(e),
                          ],
                        ],
                      ),
              ),
              if (c.selectedId == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('${counts.reviewed} of ${counts.total} reviewed',
                      key: const ValueKey('progress'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ),
            ]),
          );
        }),
      ),
      if (c.selectedId != null)
        Positioned.fill(
          child: DraggableScrollableSheet(
            key: const ValueKey('event-sheet'),
            initialChildSize: 0.62,
            minChildSize: 0.3,
            maxChildSize: 0.95,
            snap: true,
            snapSizes: const [0.3, 0.62, 0.95],
            builder: (context, scrollController) => Material(
              color: AppColors.background,
              elevation: 0,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                side: BorderSide(color: AppColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                // The header, signal and note scroll (and dragging them resizes the
                // sheet); Confirm and Dismiss stay put at the bottom.
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: Column(children: [
                      Center(
                        child: Container(
                          width: 38,
                          height: 4,
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                      EventSheetBody(controller: c),
                    ]),
                  ),
                ),
                EventSheetFooter(controller: c),
              ]),
            ),
          ),
        ),
    ]);
  }

  Widget _row(ReviewEvent e) => KeyedSubtree(
        key: GlobalObjectKey(e.event.id),
        child: ReviewRow(
          review: e,
          when: _when(e),
          durationSec: _duration(e),
          selected: e.event.id == controller.selectedId,
          onTap: () => controller.select(e.event.id),
          spark: e.isMarker ? null : controller.sparkFor(e.event.id),
        ),
      );
}

class _GroupHeader extends StatelessWidget {
  final String title;
  final int count;
  const _GroupHeader(this.title, this.count);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 8, 0, 6),
        child: Text('$title ($count)',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
      );
}

class _EmptyList extends StatelessWidget {
  final bool hasEvents;
  const _EmptyList({required this.hasEvents});

  @override
  Widget build(BuildContext context) => Center(
        child: Text(
          hasEvents ? 'No events match this filter in these days.' : 'This recording has no events to review.',
          key: const ValueKey('empty-list'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
}

class _RangeSwitch extends StatelessWidget {
  final ReviewController controller;
  const _RangeSwitch({required this.controller});

  @override
  Widget build(BuildContext context) {
    Widget seg(RangeMode m, String label) {
      final on = controller.mode == m;
      return GestureDetector(
        key: ValueKey('mode-${m.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => controller.setMode(m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration:
              ShapeDecoration(color: on ? AppColors.accentSoft : Colors.transparent, shape: const StadiumBorder()),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  color: on ? AppColors.navy : AppColors.textSecondary)),
        ),
      );
    }

    return DecoratedBox(
      decoration:
          ShapeDecoration(color: AppColors.surface, shape: StadiumBorder(side: BorderSide(color: AppColors.border))),
      child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [seg(RangeMode.oneDay, 'Day'), seg(RangeMode.week, 'Week'), seg(RangeMode.month, 'Month')]),
    );
  }
}

/// "History", with search and filter.
class _Header extends StatelessWidget {
  final ReviewController controller;
  const _Header({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Text('History', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
        IconButton(
          key: const ValueKey('search'),
          tooltip: 'Search',
          icon: Icon(c.query.isNotEmpty || c.searching ? Icons.search_off : Icons.search),
          onPressed: c.toggleSearch,
        ),
        IconButton(
          key: const ValueKey('filter'),
          tooltip: 'Filter and sort',
          icon: Badge(
            isLabelVisible: c.filter != ReviewFilter.all || c.sort != ReviewSort.score,
            smallSize: 8,
            child: const Icon(Icons.tune),
          ),
          onPressed: () => showFilterSheet(context, c),
        ),
      ]),
      if (c.searching)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: TextField(
            key: const ValueKey('search-field'),
            autofocus: true,
            onChanged: c.setQuery,
            decoration: InputDecoration(
              hintText: 'Search by kind, date, time or note',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
    ]);
  }
}

/// What is narrowing the list, each with a cross to remove it.
class _ActiveFilters extends StatelessWidget {
  final ReviewController controller;
  const _ActiveFilters({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    Widget chip(String key, String label, VoidCallback onRemove) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: InputChip(
            key: ValueKey(key),
            label: Text(label),
            onDeleted: onRemove,
            visualDensity: VisualDensity.compact,
            backgroundColor: AppColors.surface,
            side: const BorderSide(color: AppColors.border),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          if (c.filter != ReviewFilter.all)
            chip('active-status', FilterChips.label(c.filter), () => c.setFilter(ReviewFilter.all)),
          if (c.category != null) chip('active-category', categoryName(c.category!), () => c.setCategory(null)),
          if (c.query.isNotEmpty) chip('active-query', '"${c.query}"', () => c.setQuery('')),
        ]),
      ),
    );
  }
}

/// The status filter and the sort order, in a sheet from the filter icon.
Future<void> showFilterSheet(BuildContext context, ReviewController c) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => ListenableBuilder(
      listenable: c,
      builder: (context, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Show',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            FilterChips(value: c.filter, onChanged: c.setFilter),
            const SizedBox(height: 18),
            const Text('Order',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final (s, label) in [
                (ReviewSort.score, 'Highest score'),
                (ReviewSort.newest, 'Newest first'),
                (ReviewSort.oldest, 'Oldest first')
              ])
                ChoiceChip(
                  key: ValueKey('sort-${s.name}'),
                  label: Text(label),
                  selected: c.sort == s,
                  onSelected: (_) => c.setSort(s),
                  showCheckmark: false,
                  selectedColor: AppColors.accentSoft,
                  backgroundColor: AppColors.surface,
                  side: BorderSide(color: c.sort == s ? AppColors.accent : AppColors.border),
                  visualDensity: VisualDensity.compact,
                ),
            ]),
          ]),
        ),
      ),
    ),
  );
}
