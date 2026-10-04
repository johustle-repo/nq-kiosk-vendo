// Vendo Kiosk dashboard helpers (no build step; served as a static file).
(function () {
  'use strict';

  // Show UTC timestamps in the viewer's local time zone.
  document.querySelectorAll('time[datetime]').forEach(function (el) {
    var d = new Date(el.getAttribute('datetime'));
    if (!isNaN(d)) { el.title = el.textContent; el.textContent = d.toLocaleString(); }
  });

  // Confirmation for destructive forms.
  document.querySelectorAll('form[data-confirm]').forEach(function (f) {
    f.addEventListener('submit', function (e) {
      if (!window.confirm(f.getAttribute('data-confirm'))) { e.preventDefault(); }
    });
  });

  function hms(s) {
    s = Math.max(0, s | 0);
    var p = function (n) { return (n < 10 ? '0' : '') + n; };
    return p(Math.floor(s / 3600)) + ':' + p(Math.floor((s % 3600) / 60)) + ':' + p(s % 60);
  }
  function ago(iso, now) {
    if (!iso) { return 'never'; }
    var t = Date.parse(iso.replace(' ', 'T') + 'Z') / 1000;
    var d = Math.max(0, now - t);
    if (d < 60) { return Math.floor(d) + ' s ago'; }
    if (d < 3600) { return Math.floor(d / 60) + ' min ago'; }
    if (d < 86400) { return Math.floor(d / 3600) + ' h ago'; }
    return Math.floor(d / 86400) + ' d ago';
  }

  // Auto-refresh cloud-reported device status on the kiosk page every 15 s.
  var kiosk = document.getElementById('kiosk');
  if (!kiosk) { return; }
  var url = '/kiosks/' + kiosk.getAttribute('data-kiosk-id') + '/status.json';
  function refresh() {
    fetch(url, { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        if (!data || !data.ok) { return; }
        data.devices.forEach(function (d) {
          var row = kiosk.querySelector('[data-device-id="' + d.id + '"]');
          if (!row) { return; }
          var set = function (field, text) { var el = row.querySelector('[data-field="' + field + '"]'); if (el) { el.textContent = text; } };
          var pill = row.querySelector('[data-field="presence"]');
          if (pill) { pill.className = 'pill ' + d.presence; pill.textContent = d.presence.toUpperCase(); }
          set('last_seen', ago(d.last_seen_at, data.server_time));
          set('reported', ago(d.status_reported_at, data.server_time));
          if (d.status && typeof d.status.remaining_s === 'number') { set('remaining', hms(d.status.remaining_s)); }
        });
      })
      .catch(function () { /* offline: keep showing the last values */ });
  }
  setInterval(refresh, 15000);
})();
