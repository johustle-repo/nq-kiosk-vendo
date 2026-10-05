import 'package:flutter/material.dart';

import '../kiosk_controller.dart';
import '../model/kiosk_state.dart';
import 'responsive.dart';
import 'theme.dart';
import 'widgets.dart';

/// Shown whenever there is no paid time (or access is blocked).
///
/// Phone portrait: one column (hero, timer, rates).
/// Phone landscape / tablet landscape: two columns (hero + timer | rates).
class PaymentScreen extends StatelessWidget {
  const PaymentScreen({
    super.key,
    required this.controller,
    required this.onAdmin,
  });

  final KioskController controller;
  final VoidCallback onAdmin;

  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    final t = Theme.of(context).textTheme;
    final blocked = s.productionBlocked;
    final reason = s.denyReason;
    final problem =
        blocked ||
        reason == 'controller_lost' ||
        reason == 'controller_not_paired';
    final (noticeIcon, noticeTitle, noticeColor) = blocked
        ? (Icons.gpp_bad, 'Kiosk not provisioned', KioskPalette.danger)
        : reason == 'controller_lost'
        ? (Icons.portable_wifi_off, 'Coin box disconnected', KioskPalette.warn)
        : (Icons.link_off, 'Coin box not paired', KioskPalette.warn);
    final noticeDetail = !blocked && reason == 'controller_not_paired'
        ? "Coins can't be accepted yet. Ask the administrator to pair the coin box with this kiosk."
        : denyReasonText(blocked ? 'not_device_owner' : reason);

    final banners = <Widget>[
      if (s.recentlyExpired && !blocked)
        InfoBanner(
          key: const Key('expired-banner'),
          icon: Icons.timer_off,
          text: s.expiredReason == 'controller_lost'
              ? 'Session paused: the coin controller stopped responding.'
              : 'Time expired. Insert a coin to continue.',
          background: KioskPalette.danger.withValues(alpha: 0.14),
          foreground: KioskPalette.danger,
        ),
    ];

    Widget hero(Responsive r) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (problem) ...[
          StatusNotice(
            key: blocked ? const Key('blocked-banner') : null,
            icon: noticeIcon,
            title: noticeTitle,
            detail: noticeDetail,
            color: noticeColor,
            large: !r.isCompact && !r.isLandscapePhone,
          ),
        ] else ...[
          Center(child: InsertCoinButton(large: !r.isCompact && !r.isLandscapePhone)),
          if (!r.isLandscapePhone) ...[
            SizedBox(height: r.isCompact ? 10 : 16),
            Text(
              'Drop a coin in the slot. Your time starts right away.',
              textAlign: TextAlign.center,
              style: (r.isCompact ? t.bodyLarge : t.titleMedium)?.copyWith(
                color: KioskPalette.textMuted,
              ),
            ),
          ],
        ],
        SizedBox(height: r.isLandscapePhone ? 12 : (r.isCompact ? 20 : 28)),
        // The timer doubles as the hidden admin entry (tap it 7 times quickly).
        AdminEntry(
          onTriggered: onAdmin,
          child: TimePill(remainingMs: s.remainingMs, large: !r.isCompact && !r.isLandscapePhone),
        ),
      ],
    );

    Widget rates(Responsive r) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RateTable(secondsPerPulse: s.secondsPerPulse, large: !r.isCompact && !r.isLandscapePhone),
        if (s.isDemo) ...[
          const SizedBox(height: 24),
          SimulatedCoinButtons(
            secondsPerPulse: s.secondsPerPulse,
            onCoin: (p) =>
                controller.bridge.simulateCoin(p).catchError((Object e) {
                  if (context.mounted) showError(context, e);
                }),
          ),
        ],
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.isDemo || s.preview) DemoBanner(preview: s.preview),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final r = Responsive.of(box);
                  final content = r.twoColumns
                      ? Row(
                          // Landscape phones: top-align so the timer never sits below the fold.
                          crossAxisAlignment: r.isLandscapePhone
                              ? CrossAxisAlignment.start
                              : CrossAxisAlignment.center,
                          children: [
                            Expanded(child: hero(r)),
                            SizedBox(width: r.gutter),
                            Expanded(child: rates(r)),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            hero(r),
                            SizedBox(height: r.isCompact ? 24 : 36),
                            rates(r),
                          ],
                        );
                  return SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: r.gutter,
                      vertical: r.isLandscapePhone ? 10 : 18,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight:
                            box.maxHeight - (r.isLandscapePhone ? 20 : 36),
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          // Tablet portrait: keep the single column comfortably narrow.
                          constraints: BoxConstraints(
                            maxWidth: r.twoColumns ? r.maxContentWidth : 640,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final b in banners) ...[
                                b,
                                const SizedBox(height: 14),
                              ],
                              content,
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
