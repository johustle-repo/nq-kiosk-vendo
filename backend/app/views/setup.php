<?php use function Vendo\Web\{h, csrf_field}; ?>
<section class="card narrow">
  <img class="login-logo" src="/assets/logo.png" alt="VeNdO — Jo-hustle Smart Android" width="280" height="105">
  <h1>First-time setup</h1>
  <?php if ($blocked): ?>
    <p><?= h($blocked) ?></p>
  <?php else: ?>
    <p>This creates the database tables and the first administrator account.
       It only works while <code>SETUP_TOKEN</code> is set in the private <code>.env</code> file and no administrator exists.</p>
    <?php if ($pending): ?>
      <p>Pending migrations: <code><?= h(implode(', ', $pending)) ?></code></p>
    <?php endif; ?>
    <form method="post" action="/setup" autocomplete="off">
      <?= csrf_field($csrf) ?>
      <label>Setup token (from .env) <input name="setup_token" type="password" required></label>
      <label>Administrator username <input name="username" required pattern="[A-Za-z0-9_.\-]{3,64}" autocomplete="username"></label>
      <label>Password (12+ characters) <input name="password" type="password" minlength="12" required autocomplete="new-password"></label>
      <label>Confirm password <input name="password_confirm" type="password" minlength="12" required autocomplete="new-password"></label>
      <button class="primary">Run migrations and create administrator</button>
    </form>
  <?php endif; ?>
</section>
