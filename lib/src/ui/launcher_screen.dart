import 'package:flutter/material.dart';

import '../bridge/kiosk_bridge.dart';
import '../kiosk_controller.dart';
import '../model/rates.dart';
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

    // Low time is shown inside the timer itself (colour + one short line).
    final lowHint = low
        ? Text(
            level == TimeLevel.critical
                ? 'Less than a minute left. Insert a coin now.'
                : 'Less than 5 minutes left. Insert a coin to add time.',
            key: const Key('low-time-banner'),
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(
              color: timeLevelColor(level),
              fontWeight: FontWeight.w700,
            ),
          )
        : null;

    // The timer doubles as the hidden admin entry (tap it 7 times quickly).
    Widget timer(Responsive r) => AdminEntry(
      onTriggered: widget.onAdmin,
      child: r.isCompact && !r.twoColumns
          ? TimerBar(
              remainingMs: s.remainingMs,
              label: 'Time left',
              hint: lowHint,
            )
          : TimerCard(
              remainingMs: s.remainingMs,
              label: 'Time remaining',
              size: r.timerSize,
              footer: lowHint,
            ),
    );

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
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'No apps are available yet. Ask the administrator to approve apps.',
                key: const Key('no-apps'),
                textAlign: TextAlign.center,
                style: t.titleMedium,
              ),
            ),
          ),
        ];
      }
      return [
        SliverPadding(
          padding: pad,
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: r.appColumns(gridWidth - pad.horizontal),
              mainAxisSpacing: r.isCompact ? 10 : 14,
              crossAxisSpacing: r.isCompact ? 10 : 14,
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
                    if (r.twoColumns) {
                      // Tablet / landscape: timer on the left, apps on the right.
                      final panelWidth = r.sidePanelWidth;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: panelWidth,
                            child: Center(
                              child: SingleChildScrollView(
                                padding: EdgeInsets.fromLTRB(
                                  r.gutter,
                                  16,
                                  r.gutter / 2,
                                  16,
                                ),
                                child: timer(r),
                              ),
                            ),
                          ),
                          Expanded(
                            child: CustomScrollView(
                              slivers: [
                                const SliverToBoxAdapter(
                                  child: SizedBox(height: 16),
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
                    }
                    // Phone / tablet portrait: timer on top, apps below.
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
                          padding: EdgeInsets.fromLTRB(side, 16, side, 16),
                          sliver: SliverToBoxAdapter(child: timer(r)),
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
    final maxIcon = compact ? 56.0 : 72.0;
    return Material(
      color: KioskPalette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: KioskPalette.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('app-${app.packageName}'),
        onTap: onTap,
        splashColor: KioskPalette.accent.withValues(alpha: 0.2),
        child: Padding(
          padding: EdgeInsets.all(compact ? 10 : 14),
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
                          color: KioskPalette.surfaceHigh,
                          borderRadius: BorderRadius.circular(18),
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
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
