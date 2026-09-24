import 'package:flutter/material.dart';

import 'data.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';

/// Orta alan: kahraman bolumu + gorev listesi.
class TaskPane extends StatelessWidget {
  const TaskPane({
    super.key,
    required this.tasks,
    required this.filter,
    required this.category,
    required this.query,
    required this.settings,
    required this.notice,
    required this.url,
    required this.onQueryJump,
    required this.onSubmitUrl,
    required this.onAction,
    required this.destOverride,
    required this.onPickFolder,
    required this.onClearOverride,
    required this.onOpenSettings,
  });

  final List<Task> tasks;
  final String filter;
  final String? category;
  final String query;
  final Settings settings;
  final String? notice;
  final TextEditingController url;
  final ValueChanged<String> onQueryJump;
  final VoidCallback onSubmitUrl;
  final void Function(Task task, String action) onAction;

  /// Siradaki indirmeler icin secilen gecici hedef ve ayarlar kisayollari.
  final String? destOverride;
  final VoidCallback onPickFolder;
  final VoidCallback onClearOverride;
  final VoidCallback onOpenSettings;

  List<Task> get _filtered {
    var list = tasks;
    if (category != null) {
      list = list.where((task) => task.category == category).toList();
    }
    if (query.isNotEmpty) {
      final needle = query.toLowerCase();
      list = list
          .where(
            (task) =>
                task.filename.toLowerCase().contains(needle) ||
                task.url.toLowerCase().contains(needle),
          )
          .toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final isDefault = filter == 'all' && category == null && query.isEmpty;
    final sections = <Widget>[];

    if (isDefault) {
      final inFlight = tasks
          .where((task) => task.status != 'completed')
          .toList();
      final done = tasks.where((task) => task.status == 'completed').toList();

      sections.add(
        _Section(
          header: SectionHeader(
            title: 'Aktif İndirmeler',
            badge: inFlight.isEmpty ? null : '${inFlight.length} görev',
            pulse: inFlight.isNotEmpty,
          ),
          child: inFlight.isEmpty
              ? const EmptyState(
                  icon: 'downloading',
                  title: 'Şu an inen bir şey yok',
                  hint: 'Yukarıdaki alana bir bağlantı yapıştırın; gerisini Serene halledecek.',
                )
              : _CardList(tasks: inFlight, onAction: onAction),
        ),
      );

      if (done.isNotEmpty) {
        sections.add(
          _Section(
            header: SectionHeader(
              title: 'Son Tamamlananlar',
              action: HoverSurface(
                onTap: () => onQueryJump('completed'),
                background: Colors.transparent,
                padding: EdgeInsets.zero,
                child: Text(
                  'Tümünü Gör',
                  style: body(
                    12,
                    weight: FontWeight.w600,
                    color: Serene.primary,
                  ),
                ),
              ),
            ),
            child: _CompletedGrid(
              tasks: done.take(8).toList(),
              onAction: onAction,
            ),
          ),
        );
      }
    } else {
      final list = _filtered;
      final title = category != null
          ? (categoryTitles[category] ?? 'Kategori')
          : (filterTitles[filter] ?? 'İndirmeler');

      sections.add(
        _Section(
          header: SectionHeader(title: title, badge: '${list.length} görev'),
          child: list.isEmpty
              ? const EmptyState(
                  icon: 'search_off',
                  title: 'Burada bir şey yok',
                  hint: 'Bu görünümde eşleşen bir indirme bulunamadı.',
                )
              : _CardList(tasks: list, onAction: onAction),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 4, bottom: 64),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Hero(
            settings: settings,
            notice: notice,
            url: url,
            onSubmitUrl: onSubmitUrl,
            destOverride: destOverride,
            onPickFolder: onPickFolder,
            onClearOverride: onClearOverride,
            onOpenSettings: onOpenSettings,
          ),
          for (final section in sections) ...[
            const SizedBox(height: 32),
            section,
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.header, required this.child});

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [header, const SizedBox(height: 16), child],
    );
  }
}

/// Karşılama bolumu ve baglanti girisi.
class Hero extends StatelessWidget {
  const Hero({
    super.key,
    required this.settings,
    required this.notice,
    required this.url,
    required this.onSubmitUrl,
    required this.destOverride,
    required this.onPickFolder,
    required this.onClearOverride,
    required this.onOpenSettings,
  });

  final Settings settings;
  final String? notice;
  final TextEditingController url;
  final VoidCallback onSubmitUrl;

  /// Ayarlar degismeden yalnizca siradaki indirmeler icin secilen klasor.
  final String? destOverride;
  final VoidCallback onPickFolder;
  final VoidCallback onClearOverride;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Serene.radiusCard),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Serene.primaryFixed.withValues(alpha: 0.2),
            Serene.primaryFixed.withValues(alpha: 0),
          ],
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Serene.primaryFixed.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SIcon('eco', size: 14, color: Serene.onPrimaryFixed),
                const SizedBox(width: 6),
                Text(
                  'Huzurlu İndirme Alanı',
                  style: body(
                    12,
                    weight: FontWeight.w600,
                    color: Serene.onPrimaryFixed,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Bugün ne indirmek istersiniz?',
            textAlign: TextAlign.center,
            style: head(36, letterSpacing: -0.6, color: Serene.onBackground),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 448),
            child: Text(
              'Bir bağlantı yapıştırın veya hızlıca dosya arayın. '
              'Her şey sakin ve düzenli bir şekilde arka planda hallolur.',
              textAlign: TextAlign.center,
              style: body(16, color: Serene.secondary, height: 1.6),
            ),
          ),
          const SizedBox(height: 32),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 672),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Serene.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(999),
                boxShadow: Serene.shadowFloat,
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      color: Serene.primaryFixed.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: SIcon('link', size: 20, color: Serene.primary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: url,
                      onSubmitted: (_) => onSubmitUrl(),
                      cursorColor: Serene.primary,
                      style: body(14),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'https:// bağlantısını buraya bırakın...',
                        hintStyle: body(14, color: Serene.outline),
                      ),
                    ),
                  ),
                  CircleButton(
                    icon: 'create_new_folder',
                    title: 'Bu indirme için farklı klasör seç',
                    size: 40,
                    iconSize: 19,
                    background: Serene.surfaceContainer,
                    hoverBackground: Serene.surfaceContainerHigh,
                    foreground: Serene.secondary,
                    onTap: onPickFolder,
                  ),
                  const SizedBox(width: 12),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: url,
                    builder: (context, value, _) {
                      final ready = value.text.trim().isNotEmpty;
                      return Opacity(
                        opacity: ready ? 1 : 0.5,
                        child: HoverSurface(
                          onTap: ready ? onSubmitUrl : null,
                          radius: 999,
                          background: Serene.primary,
                          hoverBackground: const Color(0xE63D6A4B),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              const SIcon(
                                'download',
                                size: 18,
                                color: Serene.onPrimary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'İndir',
                                style: body(
                                  14,
                                  weight: FontWeight.w500,
                                  color: Serene.onPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          HoverSurface(
            onTap: onOpenSettings,
            background: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SIcon('folder', size: 14, color: Serene.secondary),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 448),
                  child: Text(
                    settings.downloadDir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(11, color: Serene.secondary),
                  ),
                ),
                const SizedBox(width: 6),
                const SIcon('edit', size: 13, color: Serene.secondary),
              ],
            ),
          ),
          // Yalnizca siradaki indirmeler icin gecerli olan secili klasor.
          if (destOverride != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.only(
                left: 12,
                right: 6,
                top: 6,
                bottom: 6,
              ),
              decoration: BoxDecoration(
                color: Serene.primaryFixed.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Serene.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SIcon(
                    'folder_special',
                    size: 14,
                    color: Serene.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Bu indirme şuraya kaydedilecek:',
                      style: body(11, color: Serene.onPrimaryFixed),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 256),
                    child: Text(
                      destOverride!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(11, color: Serene.primary),
                    ),
                  ),
                  CircleButton(
                    icon: 'close',
                    title: 'Özel klasörü kaldır',
                    size: 24,
                    iconSize: 15,
                    background: Colors.transparent,
                    hoverBackground: Serene.primary.withValues(alpha: 0.2),
                    foreground: Serene.primary,
                    onTap: onClearOverride,
                  ),
                ],
              ),
            ),
          ],
          if (notice != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Serene.errorContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                notice!,
                style: body(12, color: Serene.onErrorContainer),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Aktif gorev karti.
class TaskCard extends StatelessWidget {
  const TaskCard({super.key, required this.task, required this.onAction});

  final Task task;
  final void Function(Task task, String action) onAction;

  @override
  Widget build(BuildContext context) {
    final chip = statusChip(task);
    return _HoverCard(
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: CardHeader(
                  style: styleOf(task),
                  name: task.filename,
                  meta: metaLine(task),
                  chip: StatusChip(
                    label: chip.label,
                    background: chip.bg,
                    foreground: chip.fg,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Row(
                children: [
                  for (final action in actionsFor(task)) ...[
                    _ActionButton(
                      action: action,
                      onTap: () => onAction(task, action.action),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                color: Serene.surfaceContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: constraints.maxWidth * percentOf(task) / 100,
                    decoration: BoxDecoration(
                      color: barTone(task),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tamamlanan gorev karti.
class CompletedCard extends StatelessWidget {
  const CompletedCard({super.key, required this.task, required this.onAction});

  final Task task;
  final void Function(Task task, String action) onAction;

  @override
  Widget build(BuildContext context) {
    return _HoverCard(
      background: Serene.surfaceContainerLow,
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Expanded(
            child: CardHeader(
              style: styleOf(task),
              name: task.filename,
              meta: metaLine(task),
              iconBox: 40,
              iconSize: 20,
              radius: 12,
              nameSize: 14,
              nameWeight: FontWeight.w500,
              metaSize: 11,
            ),
          ),
          const SizedBox(width: 16),
          Row(
            children: [
              for (final action in actionsFor(task)) ...[
                _ActionButton(
                  action: action,
                  onTap: () => onAction(task, action.action),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _CardList extends StatelessWidget {
  const _CardList({required this.tasks, required this.onAction});

  final List<Task> tasks;
  final void Function(Task task, String action) onAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final task in tasks) ...[
          TaskCard(task: task, onAction: onAction),
          if (task != tasks.last) const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _CompletedGrid extends StatelessWidget {
  const _CompletedGrid({required this.tasks, required this.onAction});

  final List<Task> tasks;
  final void Function(Task task, String action) onAction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 16.0;
        final columns = constraints.maxWidth >= 560 ? 2 : 1;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final task in tasks)
              SizedBox(
                width: width,
                child: CompletedCard(task: task, onAction: onAction),
              ),
          ],
        );
      },
    );
  }
}

/// Kart yuzeyi; hover'da golge buyur.
class _HoverCard extends StatefulWidget {
  const _HoverCard({
    required this.child,
    this.background = Serene.surfaceContainerLowest,
    this.padding = const EdgeInsets.all(24),
  });

  final Widget child;
  final Color background;
  final EdgeInsets padding;

  @override
  State<_HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<_HoverCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: widget.padding,
        decoration: BoxDecoration(
          color: widget.background,
          borderRadius: BorderRadius.circular(Serene.radiusCard),
          boxShadow: _hover ? Serene.shadowFloat : Serene.shadowSoft,
        ),
        child: widget.child,
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.onTap});

  final TaskAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (background, hover, foreground) = switch (action.tone) {
      1 => (
        Serene.errorContainer.withValues(alpha: 0.5),
        Serene.errorContainer,
        Serene.onErrorContainer,
      ),
      2 => (
        Serene.primary.withValues(alpha: 0.1),
        Serene.primary.withValues(alpha: 0.2),
        Serene.primary,
      ),
      _ => (
        Serene.surfaceContainer,
        Serene.surfaceContainerHigh,
        Serene.secondary,
      ),
    };

    return CircleButton(
      icon: action.icon,
      title: action.title,
      background: background,
      hoverBackground: hover,
      foreground: foreground,
      onTap: onTap,
    );
  }
}

/// "Tarayıcıdan" panelindeki kart.
class CaptureCard extends StatelessWidget {
  const CaptureCard({super.key, required this.item, required this.onAction});

  final CaptureItem item;
  final void Function(CaptureItem item, String action) onAction;

  @override
  Widget build(BuildContext context) {
    final style = captureKindStyle(item.kind, item.contentType);
    final name = captureName(item);
    final line = [
      if (item.site.trim().isNotEmpty) item.site.trim(),
      item.size > 0 ? fmtBytes(item.size) : 'Boyut bilinmiyor',
      fmtWhen(item.createdAt),
    ].join(' • ');

    return _HoverCard(
      background: Serene.surfaceContainerLow,
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Expanded(
            child: CardHeader(
              style: style,
              name: name,
              meta: line,
              iconBox: 40,
              iconSize: 20,
              radius: 12,
              nameSize: 14,
              nameWeight: FontWeight.w500,
              metaSize: 11,
              chip: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: item.kind == 'hls'
                      ? const Color(0x80D3EBD8)
                      : item.kind == 'dash'
                      ? const Color(0x80F8E0A8)
                      : Serene.surfaceContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  captureKindLabel(item.kind),
                  style: body(
                    10,
                    weight: FontWeight.w600,
                    color: item.kind == 'hls'
                        ? Serene.onPrimaryFixed
                        : item.kind == 'dash'
                        ? Serene.onTertiaryContainer
                        : Serene.secondary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Row(
            children: [
              CircleButton(
                icon: 'close',
                title: 'Yoksay',
                background: Serene.surfaceContainer,
                hoverBackground: Serene.surfaceContainerHigh,
                foreground: Serene.secondary,
                onTap: () => onAction(item, 'dismiss'),
              ),
              const SizedBox(width: 6),
              CircleButton(
                icon: 'download',
                title: 'İndir',
                background: Serene.primary.withValues(alpha: 0.1),
                hoverBackground: Serene.primary.withValues(alpha: 0.2),
                foreground: Serene.primary,
                onTap: () => onAction(item, 'download'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Tarayıcıdan" kok gorunumu.
class CapturesPane extends StatelessWidget {
  const CapturesPane({
    super.key,
    required this.items,
    required this.notice,
    required this.onAction,
    required this.onClear,
  });

  final List<CaptureItem> items;
  final String? notice;
  final void Function(CaptureItem item, String action) onAction;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 4, bottom: 64),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Tarayıcıdan',
            badge: items.isEmpty ? null : '${items.length} medya',
            trailing: items.isEmpty
                ? null
                : HoverSurface(
                    onTap: onClear,
                    background: Colors.transparent,
                    padding: EdgeInsets.zero,
                    child: Text(
                      'Tümünü Temizle',
                      style: body(
                        12,
                        weight: FontWeight.w600,
                        color: Serene.secondary,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          if (notice != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Serene.errorContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  notice!,
                  style: body(12, color: Serene.onErrorContainer),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (items.isEmpty)
            EmptyState(
              icon: 'travel_explore',
              title: 'Yakalanan medya yok',
              hint:
                  'Tarayıcıda oynattığınız videolar ve sesler burada birikir; '
                  'indirmek istediğinizi tek tıkla seçersiniz.',
            )
          else
            Column(
              children: [
                for (final item in items) ...[
                  CaptureCard(item: item, onAction: onAction),
                  if (item != items.last) const SizedBox(height: 16),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
