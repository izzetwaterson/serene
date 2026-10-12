import 'package:flutter/material.dart';

import 'data.dart';
import 'format.dart';
import 'strings.dart';
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
            title: T.activeDownloads,
            badge: inFlight.isEmpty ? null : T.taskCount(inFlight.length),
            pulse: inFlight.isNotEmpty,
          ),
          child: inFlight.isEmpty
              ? EmptyState(
                  icon: 'downloading',
                  title: T.nothingDownloading,
                  hint: T.nothingDownloadingHint,
                )
              : _CardList(tasks: inFlight, onAction: onAction),
        ),
      );

      if (done.isNotEmpty) {
        sections.add(
          _Section(
            header: SectionHeader(
              title: T.recentCompleted,
              action: HoverSurface(
                onTap: () => onQueryJump('completed'),
                background: Colors.transparent,
                padding: EdgeInsets.zero,
                child: Text(
                  T.seeAll,
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
          ? (categoryTitles[category] ?? T.categoryFallback)
          : (filterTitles[filter] ?? T.downloads);

      sections.add(
        _Section(
          header: SectionHeader(
            title: title,
            badge: T.taskCount(list.length),
          ),
          child: list.isEmpty
              ? EmptyState(
                  icon: 'search_off',
                  title: T.nothingHere,
                  hint: T.nothingHereHint,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          // Bos durum once bos oldugu icin baslik yeterli bir sinyal; ayrica
          // bir rozet eklemek ayni mesaji ikinci kez soyleyip gorseli
          // gurultuluyordu. Kaldirildi.
          //
          // Alt satir ("Paste a link or quickly search for a file...") da
          // kaldirildi: alanin ipucu metni zaten ayni seyi soyluyor ve iki
          // satirlik marka cumlesi, gunluk kullanilan bir listede gercek isi
          // asagi itiyordu. Panelin yesil gradyani da gitti; hicbir islevi
          // yoktu, yalnizca leke gibi duruyordu.
          Text(
            T.heroTitle,
            textAlign: TextAlign.center,
            style: head(30, letterSpacing: -0.4, color: Serene.onBackground),
          ),
          const SizedBox(height: 20),
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
                  // Buradaki baglanti ikonu kaldirildi: kutunun hemen solunda
                  // zaten bir ikon var, ikisi ayni seyi soyluyordu. Bos
                  // 12px bosluk girdi yerine; ipucu metni ("Drop an https://
                  // link here...") zaten alani doluyor.
                  const SizedBox(width: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: url,
                      onSubmitted: (_) => onSubmitUrl(),
                      cursorColor: Serene.primary,
                      style: body(14),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: T.urlPlaceholder,
                        hintStyle: body(14, color: Serene.outline),
                      ),
                    ),
                  ),
                  CircleButton(
                    icon: 'create_new_folder',
                    title: T.chooseDifferentFolder,
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
                          hoverBackground: Serene.primaryHover,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              SIcon(
                                'download',
                                size: 18,
                                color: Serene.onPrimary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                T.downloadWord,
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
                SIcon('folder', size: 14, color: Serene.secondary),
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
                SIcon('edit', size: 13, color: Serene.secondary),
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
                  SIcon(
                    'folder_special',
                    size: 14,
                    color: Serene.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      T.willBeSavedTo,
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
                    title: T.removeCustomFolder,
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
          ProgressBar(ratio: percentOf(task) / 100, tone: barTone(task)),
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
          // Yeni kart yumusak belirir. Anahtar sart: yeni gorev listenin
          // BASINA ekleniyor, anahtarsiz eslesme yuzunden tum kartlar yeniden
          // animasyona girerdi. Yalniz opaklik + kaydirma; layout'a dokunmaz
          // ve 180 ms'de biter, kendini tekrarlamaz.
          TweenAnimationBuilder<double>(
            key: ValueKey(task.id),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: TaskCard(task: task, onAction: onAction),
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * 8),
                child: child,
              ),
            ),
          ),
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
    this.background,
    this.padding = const EdgeInsets.all(24),
  });

  final Widget child;

  /// `null` kart yuzeyini kullanir; palet cagri aninda okunur.
  final Color? background;
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
          color: widget.background ?? Serene.surfaceContainerLowest,
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

/// Panoda yakalanan baglanti uyarisi.
///
/// Tauri kabugundaki `showClipboardToast` tasariminin Flutter karsiligi: alt
/// saga yaslanmis kart, baglantiyi tek satirlik mono yaziyla gosterir ve
/// kullaniciya iki secenek verir. Kendi basina indirme yapmaz; onay kullaniciya
/// birakilir. `cards.dart` icinde tutulur cunku kayan kartlar bu dosyada.
class ClipboardToast extends StatelessWidget {
  const ClipboardToast({
    super.key,
    required this.url,
    required this.onDismiss,
    required this.onDownload,
  });

  final String url;
  final VoidCallback onDismiss;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 370,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Serene.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(Serene.radiusCard),
        border: Border.all(color: Serene.borderSoft),
        boxShadow: Serene.shadowFloat,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Serene.primaryFixed.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(Serene.radiusTile),
                ),
                child: Center(
                  child: SIcon(
                    'link',
                    size: 19,
                    color: Serene.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      T.clipboardToastTitle,
                      style: body(13, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(11, color: Serene.secondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _ToastButton(
                label: T.clipboardDismiss,
                onTap: onDismiss,
              ),
              const SizedBox(width: 8),
              _ToastButton(
                label: T.clipboardDownload,
                onTap: onDownload,
                filled: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Durum dosyasi yazilamadiginda gosterilen kalici uyari bandi.
///
/// Kirmizi bir "kayit yok" uyarisi; iki satirlik kisa bir mesaj ve tek bir
/// kapat dugmesi. Amacı kullaniciyi kandirmamak: indirmeler sürebilir ama
/// liste kaydedilmiyor, uygulama kapanınca liste geri döner.
class StorageErrorBanner extends StatelessWidget {
  const StorageErrorBanner({
    super.key,
    required this.detail,
    required this.onDismiss,
  });

  /// Motorun yazdigi dosya yolu ve sebep; kullaniciya gosterilebilir bicimde.
  final String detail;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Serene.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              SIcon('error', size: 18, color: Serene.onErrorContainer),
              const SizedBox(width: 10),
              Text(
                T.storageErrorTitle,
                style: body(13, weight: FontWeight.w600, color: Serene.onErrorContainer),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(11, color: Serene.onErrorContainer),
                ),
              ),
              const SizedBox(width: 12),
              HoverSurface(
                onTap: onDismiss,
                background: Colors.transparent,
                hoverBackground: Serene.error,
                radius: 999,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Text(
                  T.storageErrorDismiss,
                  style: body(12, weight: FontWeight.w500, color: Serene.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Toast'un iki dugmesi: birincil dolu, ikincil saydam.
class _ToastButton extends StatelessWidget {
  const _ToastButton({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return HoverSurface(
      onTap: onTap,
      background: filled ? Serene.primary : Colors.transparent,
      hoverBackground:
          filled ? Serene.primaryHover : Serene.surfaceContainerHigh,
      radius: 999,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        label,
        style: body(
          12,
          weight: FontWeight.w500,
          color: filled ? Serene.onPrimary : Serene.secondary,
        ),
      ),
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
      item.size > 0 ? fmtBytes(item.size) : T.unknownSize,
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
                      ? Serene.tintPrimaryStrong
                      : item.kind == 'dash'
                      ? Serene.tintTertiaryStrong
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
                title: T.ignore,
                background: Serene.surfaceContainer,
                hoverBackground: Serene.surfaceContainerHigh,
                foreground: Serene.secondary,
                onTap: () => onAction(item, 'dismiss'),
              ),
              const SizedBox(width: 6),
              CircleButton(
                icon: 'download',
                title: T.downloadWord,
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
            title: T.fromBrowser,
            badge: items.isEmpty ? null : T.mediaCount(items.length),
            trailing: items.isEmpty
                ? null
                : HoverSurface(
                    onTap: onClear,
                    background: Colors.transparent,
                    padding: EdgeInsets.zero,
                    child: Text(
                      T.clearAll,
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
              title: T.noCapturedMedia,
              hint: T.noCapturedMediaHint,
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
