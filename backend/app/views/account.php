<?php use function Vendo\Web\{h, csrf_field}; ?>
<section class="card narrow">
  <h1>Change password</h1>
  <p class="muted">Changing your password signs out all other sessions.</p>
  <form method="post" action="/account">
    <?= csrf_field($csrf) ?>
    <label>Current password <input name="current_password" type="password" required autocomplete="current-password"></label>
    <label>New password (12+ characters) <input name="new_password" type="password" minlength="12" required autocomplete="new-password"></label>
    <label>Confirm new password <input name="new_password_confirm" type="password" minlength="12" required autocomplete="new-password"></label>
    <button class="primary">Change password</button>
  </form>
</section>
