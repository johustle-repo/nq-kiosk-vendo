<?php use function Vendo\Web\{h, csrf_field}; ?>
<section class="card">
  <h1>Kiosks</h1>
  <p class="notice">Status on this dashboard is <strong>cloud-reported</strong>: what each device last sent over the internet.
     It can lag behind, or show offline while the kiosk keeps working locally. The ESP8266 coin controller is the only
     authority for paid time; the dashboard never grants time.</p>
  <div class="grid">
  <?php foreach ($kiosks as $k): ?>
    <a class="kiosk-card" href="/kiosks/<?= (int) $k['id'] ?>">
      <h2><?= h($k['name']) ?></h2>
      <?php if (!$k['devices']): ?><p class="muted">No devices enrolled yet.</p><?php endif; ?>
      <?php foreach ($k['devices'] as $d) { include __DIR__ . '/_device_status.php'; } ?>
    </a>
  <?php endforeach; ?>
  </div>
  <?php if (!$kiosks): ?><p class="muted">No kiosks yet. Create one to generate enrollment codes for the phone and coin controller.</p><?php endif; ?>
</section>
<section class="card narrow">
  <h2>Add a kiosk</h2>
  <form method="post" action="/kiosks"><?= csrf_field($csrf) ?>
    <label>Kiosk name <input name="name" required maxlength="100" placeholder="e.g. Store front kiosk"></label>
    <button class="primary">Create kiosk</button>
  </form>
</section>
