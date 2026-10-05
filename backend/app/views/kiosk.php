<?php use function Vendo\Web\{h, hms, ago, ts, csrf_field}; ?>
<p><a href="/">&larr; All kiosks</a></p>
<section class="card" id="kiosk" data-kiosk-id="<?= (int) $kiosk['id'] ?>">
  <h1><?= h($kiosk['name']) ?></h1>
  <p class="notice">Cloud-reported status (not live). Paid access on the phone is decided locally by the ESP8266;
     an offline row here does not mean the kiosk is down. Devices are marked <strong>OFFLINE</strong> when they have not
     reported recently.</p>
  <div class="scroll"><table>
    <thead><tr><th>Status</th><th>Type</th><th>Name</th><th>Device ID</th><th>Last contact</th><th>Reported state</th><th>Config</th><th>Version</th><th></th></tr></thead>
    <tbody>
    <?php foreach ($devices as $d): $s = $d['status']; ?>
      <tr data-device-id="<?= (int) $d['id'] ?>">
        <td><span class="pill <?= h($d['presence']) ?>" data-field="presence"><?= h(strtoupper($d['presence'])) ?></span></td>
        <td><?= $d['device_type'] === 'phone' ? 'Phone' : 'Coin controller' ?></td>
        <td><?= h($d['name']) ?><?php if ($d['hardware_id']): ?><div class="muted small"><?= h($d['hardware_id']) ?></div><?php endif; ?></td>
        <td><code><?= h($d['public_id']) ?></code></td>
        <td><span data-field="last_seen"><?= h(ago($d['last_seen_at'])) ?></span><div class="muted small"><?= h($d['last_ip']) ?></div></td>
        <td>
          <?php if ($s && $d['device_type'] === 'controller'): ?>
            Remaining <strong data-field="remaining"><?= h(hms((int) ($s['remaining_s'] ?? 0))) ?></strong> (<?= h($s['session'] ?? '?') ?>)<br>
            <span class="muted small">as of <span data-field="reported"><?= h(ago($d['status_reported_at'])) ?></span>
            · seq <?= (int) ($s['seq'] ?? 0) ?> · boot <?= h($d['status_boot_id']) ?>
            · rate <?= (int) ($s['seconds_per_pulse'] ?? 0) ?> s per peso
            <?php if (!empty($s['dropped_events'])): ?> · <span class="bad"><?= (int) $s['dropped_events'] ?> events dropped (buffer overflow)</span><?php endif; ?>
            <?php if (isset($s['wifi_rssi'])): ?> · RSSI <?= (int) $s['wifi_rssi'] ?> dBm<?php endif; ?></span>
          <?php elseif ($s && $d['device_type'] === 'phone'): ?>
            Mode <strong><?= h($s['mode'] ?? '?') ?></strong> · Device owner <?= !empty($s['device_owner']) ? 'yes' : '<span class="bad">no</span>' ?>
            · Lock task <?= h($s['lock_task'] ?? '?') ?> · Access <?= h($s['access'] ?? '?') ?><br>
            <span class="muted small">Local controller: <?= h($s['controller_link'] ?? '?') ?>
              <?php if (isset($s['controller_remaining_s'])): ?>, phone sees <?= h(hms((int) $s['controller_remaining_s'])) ?><?php endif; ?>
              · as of <?= h(ago($d['status_reported_at'])) ?> · <?= h($s['model'] ?? '') ?></span>
          <?php else: ?><span class="muted">No report yet</span><?php endif; ?>
        </td>
        <td><?php if ($d['config_version_applied'] === null): ?>—<?php elseif ((int) $d['config_version_applied'] >= (int) $config['version']): ?>v<?= (int) $d['config_version_applied'] ?> ✓<?php else: ?><span class="warn">v<?= (int) $d['config_version_applied'] ?> (v<?= (int) $config['version'] ?> pending)</span><?php endif; ?></td>
        <td><?= h($d['sw_version'] ?? '—') ?></td>
        <td><?php if ($d['revoked_at'] === null): ?>
          <form method="post" action="/devices/<?= (int) $d['id'] ?>/revoke" data-confirm="Revoke this device credential? It will stop reporting until re-enrolled."><?= csrf_field($csrf) ?><button class="danger small">Revoke</button></form>
        <?php else: ?><span class="muted small">revoked <?= h(ago($d['revoked_at'])) ?></span><?php endif; ?></td>
      </tr>
    <?php endforeach; ?>
    <?php if (!$devices): ?><tr><td colspan="9" class="muted">No devices enrolled. Generate an enrollment code below.</td></tr><?php endif; ?>
    </tbody>
  </table></div>
</section>

<section class="card">
  <h2>Enroll a device</h2>
  <?php if ($new_code): ?>
    <div class="code-box">
      <div>One-time <?= $new_code['type'] === 'phone' ? 'phone' : 'coin controller' ?> enrollment code (valid 30 minutes, shown once):</div>
      <div class="code"><?= h($new_code['code']) ?></div>
      <div class="muted small"><?= $new_code['type'] === 'phone'
        ? 'On the kiosk phone: Admin settings → Cloud → Enroll, then type this code.'
        : 'On the ESP8266 setup page (Wi-Fi “VendoCoin-…”, http://192.168.4.1), enter this code under “Cloud enrollment code”.' ?></div>
    </div>
  <?php endif; ?>
  <div class="row">
    <form method="post" action="/kiosks/<?= (int) $kiosk['id'] ?>/enroll-code"><?= csrf_field($csrf) ?>
      <input type="hidden" name="device_type" value="phone"><button>Generate phone code</button></form>
    <form method="post" action="/kiosks/<?= (int) $kiosk['id'] ?>/enroll-code"><?= csrf_field($csrf) ?>
      <input type="hidden" name="device_type" value="controller"><button>Generate coin controller code</button></form>
  </div>
</section>

<section class="card">
  <h2>Configuration <span class="muted">(version <?= (int) $config['version'] ?>)</span></h2>
  <p class="muted small">Saving creates a new version. Devices apply it on their next sync and report the version they applied.
     Rate changes apply to <strong>future</strong> coins only; time already paid is never recalculated.</p>
  <form method="post" action="/kiosks/<?= (int) $kiosk['id'] ?>/config"><?= csrf_field($csrf) ?>
    <div class="row">
      <label>Seconds per peso <input name="seconds_per_pulse" type="number" min="10" max="3600" required value="<?= (int) $config['seconds_per_pulse'] ?>"></label>
      <label>Local connection-loss timeout (s) <input name="local_loss_timeout_s" type="number" min="5" max="600" required value="<?= (int) $config['local_loss_timeout_s'] ?>"></label>
      <label>Controller cloud sync interval (s) <input name="controller_sync_interval_s" type="number" min="5" max="300" required value="<?= (int) $config['controller_sync_interval_s'] ?>"></label>
    </div>
    <p class="small rates">
      <?php $spp = (int) $config['seconds_per_pulse']; foreach ([1, 5, 10, 20] as $p): ?>
        <span>₱<?= $p ?> = <?= h(rtrim(rtrim(number_format($p * $spp / 60, 1), '0'), '.')) ?> min</span>
      <?php endforeach; ?>
    </p>
    <label>Allowed Android app package names (one per line)
      <textarea name="allowed_packages" rows="6" spellcheck="false" placeholder="com.google.android.youtube"><?= h(implode("\n", $config['allowed_packages'])) ?></textarea></label>
    <p class="muted small">When the phone receives a new version it replaces its local app selection with this list
       (only apps actually installed and launchable are shown). Local changes made later on the phone stay until the next new version here.</p>
    <button class="primary">Save new configuration version</button>
  </form>
  <details><summary>Configuration history</summary>
    <table><thead><tr><th>Version</th><th>s/peso</th><th>Loss timeout</th><th>Sync</th><th>Apps</th><th>By</th><th>When</th></tr></thead><tbody>
    <?php foreach ($history as $c): ?>
      <tr><td>v<?= (int) $c['version'] ?></td><td><?= (int) $c['seconds_per_pulse'] ?></td><td><?= (int) $c['local_loss_timeout_s'] ?> s</td>
          <td><?= (int) $c['controller_sync_interval_s'] ?> s</td><td><?= count(json_decode((string) $c['allowed_packages'], true) ?: []) ?></td>
          <td><?= h($c['username'] ?? '—') ?></td><td><?= ts($c['created_at']) ?></td></tr>
    <?php endforeach; ?>
    </tbody></table>
  </details>
</section>

<section class="card">
  <h2>Coin events</h2>
  <p class="muted small">All-time totals: <?= (int) $totals['credits'] ?> coins, ₱<?= (int) $totals['pulses'] ?>,
     <?= h(hms((int) $totals['seconds'])) ?> of time sold. Retried uploads are de-duplicated by (device, boot, sequence).</p>
  <div class="scroll"><table>
    <thead><tr><th>When</th><th>Type</th><th>Pesos</th><th>Added</th><th>Remaining after</th><th>Session</th><th>Boot / seq</th><th>Rate ver.</th></tr></thead>
    <tbody>
    <?php foreach ($events as $e): ?>
      <tr><td><?= ts($e['occurred_at']) ?></td><td><?= h($e['event_type']) ?></td><td>₱<?= (int) $e['pulses'] ?></td>
          <td><?= $e['event_type'] === 'credit' ? h(intdiv((int) $e['seconds_added'], 60) . ' min') : '—' ?></td>
          <td><?= h(hms((int) $e['remaining_after'])) ?></td><td>#<?= (int) $e['session_no'] ?></td>
          <td><code><?= h($e['boot_id']) ?></code> / <?= (int) $e['seq'] ?></td><td><?= (int) $e['rate_version'] ?></td></tr>
    <?php endforeach; ?>
    <?php if (!$events): ?><tr><td colspan="8" class="muted">No coin events reported yet.</td></tr><?php endif; ?>
    </tbody>
  </table></div>
</section>

<section class="card">
  <h2>Session history</h2>
  <div class="scroll"><table>
    <thead><tr><th>Started</th><th>Last coin</th><th>Ended</th><th>Coins</th><th>Pesos</th><th>Time sold</th><th>Boot / session</th></tr></thead>
    <tbody>
    <?php foreach ($sessions as $s): ?>
      <tr><td><?= ts($s['started_at']) ?></td><td><?= ts($s['last_credit_at']) ?></td>
          <td><?= $s['ended_at'] ? ts($s['ended_at']) . ' <span class="muted small">' . h($s['end_reason']) . '</span>' : '<span class="muted">open / not reported</span>' ?></td>
          <td><?= (int) $s['credit_count'] ?></td><td>₱<?= (int) $s['total_pulses'] ?></td><td><?= h(hms((int) $s['total_seconds'])) ?></td>
          <td><code><?= h($s['boot_id']) ?></code> / #<?= (int) $s['session_no'] ?></td></tr>
    <?php endforeach; ?>
    <?php if (!$sessions): ?><tr><td colspan="7" class="muted">No sessions yet.</td></tr><?php endif; ?>
    </tbody>
  </table></div>
</section>
