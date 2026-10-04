<?php use function Vendo\Web\{h, csrf_field}; ?>
<section class="card">
  <h1>Diagnostics</h1>
  <?php foreach ($notes as $n): ?><div class="flash ok"><?= h($n) ?></div><?php endforeach; ?>
  <table class="kv">
    <tr><th>PHP version</th><td><?= h($php) ?></td></tr>
    <tr><th>Database driver</th><td><?= h($driver) ?></td></tr>
    <tr><th>Applied migrations</th><td><code><?= h(implode(', ', $applied)) ?></code></td></tr>
    <tr><th>Pending migrations</th><td><?= $pending ? '<strong>' . h(implode(', ', $pending)) . '</strong>' : 'none' ?></td></tr>
    <tr><th>REMOTE_ADDR</th><td><code><?= h($remote_addr) ?></code></td></tr>
    <tr><th>X-Forwarded-For</th><td><code><?= h($xff ?: '—') ?></code></td></tr>
    <tr><th>IP used for rate limits</th><td><code><?= h($client_ip) ?></code></td></tr>
    <tr><th>SETUP_TOKEN still set</th><td><?= $setup_token_set ? '<strong class="bad">yes — remove it from .env</strong>' : 'no' ?></td></tr>
  </table>
  <p class="muted">If REMOTE_ADDR shows a CDN/proxy address and X-Forwarded-For shows your real IP,
     set <code>TRUSTED_IP_HEADER=HTTP_X_FORWARDED_FOR</code> in .env so login rate limits apply per visitor.</p>
  <?php if ($pending): ?>
  <form method="post" action="/diagnostics"><?= csrf_field($csrf) ?>
    <p>Back up the database (hPanel → Databases → phpMyAdmin → Export) before applying migrations.</p>
    <button class="primary">Apply pending migrations</button>
  </form>
  <?php endif; ?>
</section>
