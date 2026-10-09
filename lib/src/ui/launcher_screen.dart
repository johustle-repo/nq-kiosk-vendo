import 'package:flutter/material.dart';

import '../bridge/kiosk_bridge.dart';
import '../kiosk_controller.dart';
import '../model/rates.dart';
import 'coin_claim.dart';
import 'responsive.dart';
import 'theme.dart';
import 'widgets.dart';

/// Paid launcher: the administrator-approved apps plus the remaining time.
///
/// The countdown is only visible while this screen is in front. Flutter cannot
/// draw over other apps; while a customer app is open the time is enforced by
/// the native service and shown on the coin controller's LCD.
class LauncherScreen extends StatefulWidget {
  const LauncherScreen({
    super.key,
    required this.controller,
    required this.onAdmin,
  });

  final KioskController controller;
  final VoidCallback onAdmin;

  @override
  State<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends State<LauncherScreen> {
  late Future<List<InstalledApp>> _apps;
  List<String> _loadedFor = const [];
  int? _lastSeqShown;

  @override
  void initState() {
    super.initState();
    _load();
    widget.controller.addListener(_onState);
  }

  void _load() {
    _loadedFor = List.of(widget.controller.state.allowedPackages);
    _apps = widget.controller.bridge.listApps(onlyAllowed: true);
  }

  void _onState() {
    final s = widget.controller.state;
    if (s.allowedPackages.join(',') != _loadedFor.join(',')) setState(_load);
    // Brief confirmation when the controller reports a new coin.
    final ago = s.lastCreditAgoMs;
    if (ago != null &&
        ago < 3000 &&
        s.controllerSeq != _lastSeqShown &&
        s.lastAddedS != null) {
      _lastSeqShown = s.controllerSeq;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('+${Rates.describeDuration(s.lastAddedS!)} added'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onState);
    super.dispose();
  }

  Future<void> _launch(InstalledApp app) async {
    try {
      await widget.controller.bridge.launchApp(app.packageName);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.state;
    final t = Theme.of(context).textTheme;
    final level = timeLevel(s.remainingMs);
    final low = level == TimeLevel.low || level == TimeLevel.critical;
    final label = s.controllerPaired && !s.isDemo
        ? 'Tablet ${s.controllerStation} · Time left'
        : 'Time left';

    // Low time is shown inside the timer itself (colour + one short line).
    final lowHint = low
        ? Text(
            level == TimeLevel.critical
                ? 'Less than a minute left. Insert a coin now.'
                : 'Less than 5 minutes left. Insert a coin to add time.',
            key: const Key('low-time-banner'),
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(
              color: timeLevelColorOnInk(level),
              fontWeight: FontWeight.w700,
            ),
          )
        : null;

    // The timer doubles as the hidden admin entry (tap it 10 times quickly).
    Widget timerOnly(Responsive r, {required bool bar}) => AdminEntry(
      onTriggered: widget.onAdmin,
      child: bar
          ? TimerBar(remainingMs: s.remainingMs, label: label, hint: lowHint)
          : TimerCard(
              remainingMs: s.remainingMs,
              label: label,
              size: r.isLandscapePhone ? r.timerSize : r.timerSize * 0.56,
              footer: lowHint,
            ),
    );

    // On a shared coin box "Add time" sits under it: coins only reach this
    // tablet after the player claims the coin box.
    Widget timer(Responsive r, {required bool bar}) {
      final t = timerOnly(r, bar: bar);
      if (!needsCoinClaim(widget.controller)) return t;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          t,
          const SizedBox(height: 8),
          AddTimeButton(controller: widget.controller),
        ],
      );
    }

    Widget appsHeader(AsyncSnapshot<List<InstalledApp>> snap, Responsive r) {
      final count = snap.data?.length ?? 0;
      return Row(
        children: [
          Expanded(
            child: SectionTitle(
              icon: Icons.apps_rounded,
              title: 'Choose an app',
              subtitle: 'Tap to open. Your time keeps running.',
              large: !r.isCompact && !r.isLandscapePhone,
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: KioskPalette.accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(40),
              ),
              child: Text(
                '$count app${count == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: KioskPalette.accentDeep,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ],
      );
    }

    List<Widget> appSlivers(
      AsyncSnapshot<List<InstalledApp>> snap,
      Responsive r,
      double gridWidth,
      EdgeInsets pad,
    ) {
      final apps = snap.data ?? const <InstalledApp>[];
      if (snap.connectionState != ConnectionState.done) {
        return const [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        ];
      }
      if (apps.isEmpty) {
        return [
          SliverPadding(
            padding: pad,
            sliver: SliverToBoxAdapter(
              child: SurfaceCard(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    const Icon(
                      Icons.apps_outage_outlined,
                      size: 44,
                      color: KioskPalette.textMuted,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No apps are available yet. Ask the administrator to approve apps.',
                      key: const Key('no-apps'),
                      textAlign: TextAlign.center,
                      style: t.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ];
      }
      final spacing = r.isCompact ? 12.0 : 16.0;
      return [
        SliverPadding(
          padding: pad,
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: r.appColumns(gridWidth - pad.horizontal),
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              childAspectRatio: r.appTileAspect,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _AppTile(
                app: apps[i],
                compact: r.isCompact,
                onTap: () => _launch(apps[i]),
              ),
              childCount: apps.length,
            ),
          ),
        ),
      ];
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.isDemo || s.preview) DemoBanner(preview: s.preview),
            Expanded(
              child: FutureBuilder<List<InstalledApp>>(
                future: _apps,
                builder: (context, snap) => LayoutBuilder(
                  builder: (context, box) {
                    final r = Responsive.of(box);
                    final wide =
                        r.isLandscapePhone ||
                        (r.width >= 840 && r.width > r.height);
                    if (wide) {
                      // Landscape: timer sidebar on the left, apps on the right.
                      final panelWidth = r.sidePanelWidth;
                      final top = r.isLandscapePhone ? 14.0 : 8.0;
                      final split = Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: panelWidth,
                            child: SingleChildScrollView(
                              padding: EdgeInsets.fromLTRB(
                                r.gutter,
                                top,
                                r.gutter / 2,
                                20,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  timer(r, bar: false),
                                  if (!r.isLandscapePhone) ...[
                                    const SizedBox(height: 12),
                                    _SessionInfo(remainingMs: s.remainingMs),
                                    const SizedBox(height: 12),
                                    RateTable(
                                      secondsPerPulse: s.secondsPerPulse,
                                      title: 'Add more time',
                                      dense: true,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: CustomScrollView(
                              slivers: [
                                SliverPadding(
                                  padding: EdgeInsets.fromLTRB(
                                    r.gutter / 2,
                                    top,
                                    r.gutter,
                                    16,
                                  ),
                                  sliver: SliverToBoxAdapter(
                                    child: appsHeader(snap, r),
                                  ),
                                ),
                                ...appSlivers(
                                  snap,
                                  r,
                                  box.maxWidth - panelWidth,
                                  EdgeInsets.fromLTRB(
                                    r.gutter / 2,
                                    0,
                                    r.gutter,
                                    24,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                      if (r.isLandscapePhone) return split;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              r.gutter,
                              18,
                              r.gutter,
                              16,
                            ),
                            child: const KioskTopBar(),
                          ),
                          Expanded(child: split),
                        ],
                      );
                    }
                    // Portrait (phone or tablet): timer on top, apps below.
                    final maxWidth = r.isCompact ? box.maxWidth : 900.0;
                    final side =
                        ((box.maxWidth - maxWidth) / 2).clamp(
                          0.0,
                          double.infinity,
                        ) +
                        r.gutter;
                    return CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(side, 14, side, 14),
                          sliver: SliverToBoxAdapter(
                            child: KioskTopBar(compact: r.isCompact),
                          ),
                        ),
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(side, 0, side, 0),
                          sliver: SliverToBoxAdapter(
                            child: r.isCompact
                                ? timer(r, bar: true)
                                : Center(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 520,
                                      ),
                                      child: timer(r, bar: false),
                                    ),
                                  ),
                          ),
                        ),
                        if (!r.isCompact)
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(side, 16, side, 0),
                            sliver: SliverToBoxAdapter(
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 520,
                                  ),
                                  child: _SessionInfo(
                                    remainingMs: s.remainingMs,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            side,
                            r.isCompact ? 18 : 28,
                            side,
                            14,
                          ),
                          sliver: SliverToBoxAdapter(
                            child: appsHeader(snap, r),
                          ),
                        ),
                        ...appSlivers(
                          snap,
                          r,
                          box.maxWidth - 2 * (side - r.gutter),
                          EdgeInsets.fromLTRB(side, 0, side, 24),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({
    required this.app,
    required this.onTap,
    this.compact = false,
  });

  final InstalledApp app;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final maxIcon = compact ? 54.0 : 60.0;
    final radius = BorderRadius.circular(compact ? 18 : 20);
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: kCardShadow),
      child: Material(
        color: KioskPalette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: KioskPalette.outline.withValues(alpha: 0.6)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('app-${app.packageName}'),
          onTap: onTap,
          splashColor: KioskPalette.accent.withValues(alpha: 0.18),
          highlightColor: KioskPalette.accent.withValues(alpha: 0.06),
          child: Padding(
            padding: EdgeInsets.all(compact ? 9 : 10),
            child: Column(
              children: [
                // The icon takes whatever height is left after the label, so the
                // tile never overflows (small tiles, large system fonts).
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: maxIcon,
                        maxHeight: maxIcon,
                      ),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Container(
                          padding: EdgeInsets.all(compact ? 7 : 9),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                KioskPalette.surfaceHigh,
                                KioskPalette.accent.withValues(alpha: 0.08),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(
                              compact ? 16 : 20,
                            ),
                          ),
                          child: app.icon != null
                              ? Image.memory(app.icon!, gaplessPlayback: true)
                              : const FittedBox(
                                  child: Icon(
                                    Icons.apps,
                                    color: KioskPalette.accent,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  app.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: KioskPalette.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// When the session ends and how to add time, as a small card.
class _SessionInfo extends StatelessWidget {
  const _SessionInfo({required this.remainingMs});

  final int remainingMs;

  @override
  Widget build(BuildContext context) {
    final endsAt = DateTime.now().add(Duration(milliseconds: remainingMs));
    return SurfaceCard(
      key: const Key('ends-at'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: KioskPalette.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(
              Icons.event_available_outlined,
              color: KioskPalette.accent,
              size: 19,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (remainingMs > 0)
                  Text.rich(
                    TextSpan(
                      text: 'Session ends at ',
                      children: [
                        TextSpan(
                          text: clockText(endsAt),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: KioskPalette.text,
                          ),
                        ),
                      ],
                    ),
                    style: const TextStyle(
                      fontSize: 14.5,
                      color: KioskPalette.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const Text(
                  'Insert a coin anytime to add time',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: KioskPalette.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
