<?php
use function Vendo\Web\{h, hms, ago};
/** @var array $d decorated device row */
$s = $d['status'] ?? null;
?>
<div class="device" data-device-id="<?= (int) $d['id'] ?>">
  <div class="device-head">
    <span class="pill <?= h($d['presence']) ?>" data-field="presence"><?= h(strtoupper($d['presence'])) ?></span>
    <strong><?= $d['device_type'] === 'phone' ? 'Phone' : 'Coin controller' ?>:</strong> <?= h($d['name']) ?>
  </div>
  <div class="muted small">Cloud last contact: <span data-field="last_seen"><?= h(ago($d['last_seen_at'])) ?></span></div>
  <?php if ($s && $d['device_type'] === 'controller'): ?>
    <div class="small">Reported remaining:
      <strong data-field="remaining"><?= h(hms((int) ($s['remaining_s'] ?? 0))) ?></strong>
      (<?= h($s['session'] ?? '?') ?>) — reported <span data-field="reported"><?= h(ago($d['status_reported_at'])) ?></span>
    </div>
  <?php elseif ($s && $d['device_type'] === 'phone'): ?>
    <div class="small">Mode <strong><?= h($s['mode'] ?? '?') ?></strong>,
      device owner <?= !empty($s['device_owner']) ? 'yes' : '<span class="bad">no</span>' ?>,
      access <?= h($s['access'] ?? '?') ?>, local controller link <?= h($s['controller_link'] ?? '?') ?>
      — reported <?= h(ago($d['status_reported_at'])) ?></div>
  <?php endif; ?>
</div>
