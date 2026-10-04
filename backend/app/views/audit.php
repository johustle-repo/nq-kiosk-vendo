<?php use function Vendo\Web\{h, ts}; ?>
<section class="card">
  <h1>Audit log</h1>
  <p class="muted">Configuration changes, enrollments, revocations and sign-ins (latest 200).</p>
  <div class="scroll"><table>
    <thead><tr><th>When</th><th>Action</th><th>Admin</th><th>Kiosk</th><th>Details</th><th>IP</th></tr></thead>
    <tbody>
    <?php foreach ($rows as $r): ?>
      <tr><td><?= ts($r['created_at']) ?></td><td><code><?= h($r['action']) ?></code></td><td><?= h($r['username'] ?? '—') ?></td>
          <td><?= h($r['kiosk_name'] ?? '—') ?></td><td class="details"><code><?= h($r['details']) ?></code></td><td><?= h($r['ip']) ?></td></tr>
    <?php endforeach; ?>
    <?php if (!$rows): ?><tr><td colspan="6" class="muted">No entries yet.</td></tr><?php endif; ?>
    </tbody>
  </table></div>
</section>
