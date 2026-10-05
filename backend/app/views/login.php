<?php use function Vendo\Web\{h, csrf_field}; ?>
<section class="card narrow">
  <img class="login-logo" src="/assets/logo.png" alt="VeNdO — Jo-hustle Smart Android" width="280" height="105">
  <h1>Administrator sign in</h1>
  <form method="post" action="/login" autocomplete="on">
    <?= csrf_field($csrf) ?>
    <label>Username <input name="username" required maxlength="64" autocomplete="username" value="<?= h($username ?? '') ?>"></label>
    <label>Password <input name="password" type="password" required autocomplete="current-password"></label>
    <button class="primary">Sign in</button>
  </form>
</section>
