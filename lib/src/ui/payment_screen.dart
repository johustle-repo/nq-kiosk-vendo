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
    final headline = problem ? denyReasonText(reason) : 'Insert coin to start';

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
      if (blocked)
        InfoBanner(
          key: const Key('blocked-banner'),
          icon: Icons.gpp_bad,
          text: denyReasonText('not_device_owner'),
          background: KioskPalette.danger.withValues(alpha: 0.14),
          foreground: KioskPalette.danger,
        ),
    ];

    Widget hero(Responsive r) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!r.isLandscapePhone) ...[
          Center(
            child: problem
                ? Icon(
                    Icons.portable_wifi_off,
                    size: r.coinSize * 0.8,
                    color: KioskPalette.warn,
                  )
                : CoinBadge(size: r.coinSize),
          ),
          SizedBox(height: r.isCompact ? 14 : 20),
        ],
        Text(
          headline,
          key: const Key('payment-headline'),
          textAlign: TextAlign.center,
          style:
              (r.isCompact || r.isLandscapePhone
                      ? t.headlineSmall
                      : t.displaySmall)
                  ?.copyWith(fontWeight: FontWeight.w900, color: Colors.white),
        ),
        if (!problem && !r.isLandscapePhone) ...[
          const SizedBox(height: 6),
          Text(
            'Drop a coin in the slot. Your time starts right away.',
            textAlign: TextAlign.center,
            style: (r.isCompact ? t.bodyLarge : t.titleMedium)?.copyWith(
              color: KioskPalette.textMuted,
            ),
          ),
        ],
        SizedBox(height: r.isLandscapePhone ? 12 : 20),
        // The timer doubles as the hidden admin entry (tap it 7 times quickly).
        AdminEntry(
          onTriggered: onAdmin,
          child: TimePill(remainingMs: s.remainingMs),
        ),
      ],
    );

    Widget rates(Responsive r) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RateTable(secondsPerPulse: s.secondsPerPulse),
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
                              SizedBox(height: r.isLandscapePhone ? 12 : 28),
                              // Local coin box and cloud status, kept small and out of the way.
                              Center(child: ConnectionIndicators(state: s)),
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
