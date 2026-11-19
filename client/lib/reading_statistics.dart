import 'dart:math';

import 'package:flutter/material.dart';

import 'store.dart';

String _duration(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  if (duration.inHours > 0) {
    final minutes = duration.inMinutes % 60;
    return '${duration.inHours} 小时${minutes == 0 ? '' : ' $minutes 分钟'}';
  }
  if (duration.inMinutes > 0) return '${duration.inMinutes} 分钟';
  if (duration.inSeconds > 0) return '${duration.inSeconds} 秒';
  return milliseconds == 0 ? '0 分钟' : '不足 1 秒';
}

class ReadingStatistics extends StatefulWidget {
  const ReadingStatistics(this.store, {super.key});
  final ReaderStore store;

  @override
  State<ReadingStatistics> createState() => _ReadingStatisticsState();
}

class _ReadingStatisticsState extends State<ReadingStatistics>
    with WidgetsBindingObserver {
  ReaderStore get store => widget.store;
  Json? stats;
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    stats = store.cachedReadingStats;
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    if (loading) return;
    if (store.token.isEmpty) {
      setState(() => error = '请先在「我的」中连接服务端。');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final summary = await store.loadReadingStats();
      if (mounted) setState(() => stats = summary);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        stats = store.cachedReadingStats;
        error = switch (e) {
          ApiError(status: 404) => '请更新服务端以启用阅读统计。',
          ApiError(status: 401) => '个人令牌不正确，请检查连接设置。',
          _ => '暂时无法刷新阅读统计，请检查服务连接。',
        };
      });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = stats;
    final days = rows(data?['days']);
    final books = rows(data?['books']).take(10).toList();
    final pending = store.pendingReadingPeriods;
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('阅读时长', style: theme.textTheme.titleLarge),
                      ),
                      IconButton(
                        tooltip: '刷新统计',
                        onPressed: loading ? null : refresh,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  if (loading) const LinearProgressIndicator(),
                  if (error != null || pending > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        [
                          if (error != null) error!,
                          if (error != null && data != null)
                            if (data['today'] is String)
                              '已显示 ${data['today']} 的统计快照。'
                            else
                              '已显示上次同步的统计。',
                          if (pending > 0) '本机有 $pending 段阅读时长待同步。',
                        ].join('\n'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  _TimeSummary(data),
                  if (days.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('近三个月阅读热力图', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    _ReadingHeatmap(days),
                  ],
                  if (data != null) ...[
                    const SizedBox(height: 24),
                    Text('阅读时长排行', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Card(
                      margin: EdgeInsets.zero,
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerLow,
                      child: books.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('还没有阅读时长记录'),
                            )
                          : Column(
                              children: [
                                for (final (index, book) in books.indexed)
                                  ListTile(
                                    leading: SizedBox(
                                      width: 22,
                                      child: Text('${index + 1}'),
                                    ),
                                    title: Text(
                                      (book['title'] as String?)?.isNotEmpty ==
                                              true
                                          ? book['title'] as String
                                          : '未命名书籍',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle:
                                        (book['author'] as String?)
                                                ?.isNotEmpty ==
                                            true
                                        ? Text(
                                            book['author'],
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          )
                                        : null,
                                    trailing: Text(
                                      _duration(book['milliseconds'] ?? 0),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeSummary extends StatelessWidget {
  const _TimeSummary(this.stats);
  final Json? stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String value(String key) =>
        stats == null ? '—' : _duration(stats![key] ?? 0);
    final metrics = [
      ('今日', value('todayMs')),
      ('本月', value('monthMs')),
      ('累计', value('totalMs')),
      ('本月活跃天数', stats == null ? '—' : '${stats!['activeDays']} 天'),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 640 ? 4 : 2;
        const gap = 8.0;
        final width = (box.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (label, value) in metrics)
              SizedBox(
                width: width,
                child: Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: theme.textTheme.labelLarge),
                        const SizedBox(height: 6),
                        Text(value, style: theme.textTheme.titleLarge),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ReadingHeatmap extends StatelessWidget {
  const _ReadingHeatmap(this.days);
  final List<Json> days;

  static int _level(int elapsed) => switch (elapsed) {
    0 => 0,
    < 15 * 60 * 1000 => 1,
    < 30 * 60 * 1000 => 2,
    < 60 * 60 * 1000 => 3,
    _ => 4,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = [
      for (final fraction in [0.0, .25, .48, .72, 1.0])
        Color.lerp(colors.surfaceContainerHighest, colors.primary, fraction)!,
    ];
    final dates = [
      for (final day in days) DateTime.parse('${day['date']}T00:00:00Z'),
    ];
    final leading = dates.first.weekday - 1;
    final weekCount = (leading + dates.length + 6) ~/ 7;
    final months = <int, int>{};
    for (final (i, date) in dates.indexed) {
      if (i == 0 || date.day == 1) months[(leading + i) ~/ 7] = date.month;
    }
    final calendarLabel = theme.textTheme.labelSmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, box) {
            const gutter = 20.0, gap = 3.0;
            final cell =
                ((box.maxWidth - gutter - (weekCount - 1) * gap) / weekCount)
                    .clamp(10.0, 24.0);
            final step = cell + gap;
            final width = gutter + weekCount * step - gap;
            Widget square(Color color, double size) => Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            );
            Widget dayCell(int i) {
              if (i < 0 || i >= days.length)
                return SizedBox.square(dimension: cell);
              final date = dates[i];
              final elapsed = days[i]['milliseconds'] as int;
              return Tooltip(
                triggerMode: TooltipTriggerMode.tap,
                message:
                    '${date.year}年${date.month}月${date.day}日 · ${_duration(elapsed)}',
                child: square(palette[_level(elapsed)], cell),
              );
            }

            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 22,
                      child: Stack(
                        children: [
                          for (final entry in months.entries)
                            Positioned(
                              left: min(gutter + entry.key * step, width - 28),
                              child: Text(
                                '${entry.value}月',
                                style: calendarLabel,
                              ),
                            ),
                        ],
                      ),
                    ),
                    for (final (row, label) in const [
                      '一',
                      '',
                      '三',
                      '',
                      '五',
                      '',
                      '日',
                    ].indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: gap),
                        child: Row(
                          children: [
                            SizedBox(
                              width: gutter,
                              height: cell,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(label, style: calendarLabel),
                              ),
                            ),
                            for (int col = 0; col < weekCount; col++) ...[
                              if (col > 0) const SizedBox(width: gap),
                              dayCell(col * 7 + row - leading),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
