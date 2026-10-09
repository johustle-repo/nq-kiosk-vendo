import 'package:flutter/material.dart';

import '../kiosk_controller.dart';
import '../model/kiosk_state.dart';
import 'responsive.dart';
import 'theme.dart';
import 'coin_claim.dart';
import 'widgets.dart';

/// Shown whenever there is no paid time (or access is blocked).
///
/// Top bar (logo, tablet, clock) over:
/// * landscape tablets and phones: the dark countdown panel on the left,
///   rates and "how it works" on the right;
/// * portrait: the same pieces stacked in one column.
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
          background: KioskPalette.danger.withValues(alpha: 0.10),
          foreground: KioskPalette.danger,
        ),
    ];

    // Production with a paired coin box: show which tablet this is and whether
    // the attendant has pointed the coin box at it.
    final shared = !s.isDemo && s.controllerPaired;
    final ready = shared && s.coinBoxReadyForMe;

    Widget hero(Responsive r, {required bool roomy}) => HeroPanel(
      radius: roomy ? 32 : 26,
      padding: EdgeInsets.symmetric(
        horizontal: roomy ? 36 : 20,
        vertical: roomy ? 32 : (r.isLandscapePhone ? 18 : 24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The countdown doubles as the hidden admin entry (tap it 10 times quickly).
          AdminEntry(
            onTriggered: onAdmin,
            child: HeroCountdown(
              remainingMs: s.remainingMs,
              size: roomy ? 92 : (r.isLandscapePhone ? 48 : 60),
              large: roomy,
            ),
          ),
          SizedBox(height: roomy ? 28 : 18),
          if (problem)
            StatusNotice(
              key: blocked ? const Key('blocked-banner') : null,
              icon: noticeIcon,
              title: noticeTitle,
              detail: noticeDetail,
              color: noticeColor,
              large: roomy,
              onInk: true,
            )
          else ...[
            Center(
              child: InsertCoinButton(
                large: roomy,
                onPressed: shared
                    ? () => claimCoinBox(context, controller)
                    : null,
              ),
            ),
            SizedBox(height: roomy ? 16 : 12),
            Text(
              !shared
                  ? 'Drop a coin in the slot. Your time starts right away.'
                  : ready
                  ? 'The coin box is ready for Tablet ${s.controllerStation}. Insert your coins now.'
                  : 'Tap "Insert coin to start", then insert your coins.',
              key: const Key('payment-hint'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: roomy ? 18 : 15,
                height: 1.35,
                color: ready ? KioskPalette.mint : KioskPalette.onInkMuted,
                fontWeight: ready ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );

    Widget side({required bool roomy, required bool showSteps}) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RateTable(secondsPerPulse: s.secondsPerPulse, large: roomy),
        if (showSteps) ...[SizedBox(height: 14), HowItWorks(large: roomy)],
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
                  final twoPane =
                      r.isLandscapePhone ||
                      (r.width >= 840 && r.width > r.height);
                  final roomy = !r.isCompact && !r.isLandscapePhone;
                  final gap = r.isLandscapePhone ? 14.0 : (roomy ? 28.0 : 16.0);
                  final body = twoPane
                      ? IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 6, child: hero(r, roomy: roomy)),
                              SizedBox(width: gap),
                              Expanded(
                                flex: 5,
                                child: side(
                                  roomy: roomy,
                                  showSteps: !r.isLandscapePhone,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            hero(r, roomy: roomy),
                            SizedBox(height: gap),
                            side(roomy: roomy, showSteps: true),
                          ],
                        );
                  final topPad = r.isLandscapePhone ? 10.0 : 14.0;
                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      r.gutter,
                      topPad,
                      r.gutter,
                      24,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: box.maxHeight - topPad - 24,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: twoPane
                                ? 1240
                                : (r.isCompact ? 560 : 680),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              KioskTopBar(
                                compact: !roomy,
                                trailing: shared
                                    ? TabletBadge(
                                        station: s.controllerStation,
                                        ready: ready,
                                      )
                                    : null,
                              ),
                              SizedBox(
                                height: r.isLandscapePhone
                                    ? 10
                                    : (roomy ? 18 : 16),
                              ),
                              body,
                              // Warnings (time expired, ...) sit under the content.
                              for (final b in banners) ...[
                                const SizedBox(height: 16),
                                b,
                              ],
                              if (s.isDemo) ...[
                                const SizedBox(height: 20),
                                SimulatedCoinButtons(
                                  secondsPerPulse: s.secondsPerPulse,
                                  onCoin: (p) => controller.bridge
                                      .simulateCoin(p)
                                      .catchError((Object e) {
                                        if (context.mounted) {
                                          showError(context, e);
                                        }
                                      }),
                                ),
                              ],
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
