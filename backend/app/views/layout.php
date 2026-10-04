<?php use function Vendo\Web\{h, csrf_field}; ?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title><?= h($title ?? 'Vendo Kiosk') ?> · Vendo Kiosk</title>
<link rel="stylesheet" href="/assets/app.css">
<script src="/assets/app.js" defer></script>
</head>
<body>
<header class="topbar">
  <a class="brand" href="/">Vendo Kiosk <span class="muted">admin</span></a>
  <?php if (!empty($admin)): ?>
  <nav>
    <a href="/">Kiosks</a>
    <a href="/audit">Audit log</a>
    <a href="/diagnostics">Diagnostics</a>
    <a href="/account"><?= h($admin['username']) ?></a>
    <form method="post" action="/logout" class="inline"><?= csrf_field($csrf) ?><button class="link">Sign out</button></form>
  </nav>
  <?php endif; ?>
</header>
<main>
<?php if (!empty($flash)): ?>
  <div class="flash <?= h($flash['kind']) ?>"><?= h($flash['message']) ?></div>
<?php endif; ?>
<?php if (!empty($errors)): ?>
  <div class="flash error"><ul><?php foreach ($errors as $e): ?><li><?= h($e) ?></li><?php endforeach; ?></ul></div>
<?php endif; ?>
<?= $content ?>
</main>
</body>
</html>
