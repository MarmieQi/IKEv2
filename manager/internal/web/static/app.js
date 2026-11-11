for (const button of document.querySelectorAll('[data-open]')) {
  button.addEventListener('click', () => {
    const dialog = document.getElementById(button.dataset.open);
    const form = dialog.querySelector('form');
    form.reset();
    if (button.dataset.account) {
      dialog.querySelector('[data-account-label]').textContent = button.dataset.account;
      if (form.elements.username) form.elements.username.value = button.dataset.account;
    }
    if (button.dataset.session) form.elements.id.value = button.dataset.session;
    if (button.dataset.maxSessions !== undefined) {
      form.elements.max_sessions.value = button.dataset.maxSessions;
      form.elements.upload_mbps.value = button.dataset.uploadMbps;
      form.elements.download_mbps.value = button.dataset.downloadMbps;
    }
    dialog.showModal();
  });
}

for (const button of document.querySelectorAll('[data-close]')) {
  button.addEventListener('click', () => button.closest('dialog').close());
}

const speedCells = document.querySelectorAll('[data-traffic-session]');

function formatSpeed(bitsPerSecond) {
  if (bitsPerSecond >= 1e9) return (bitsPerSecond / 1e9).toFixed(2) + ' Gbps';
  if (bitsPerSecond >= 1e6) return (bitsPerSecond / 1e6).toFixed(2) + ' Mbps';
  if (bitsPerSecond >= 1e3) return (bitsPerSecond / 1e3).toFixed(1) + ' Kbps';
  return Math.round(bitsPerSecond) + ' bps';
}

function showSpeeds(current, previous, seconds) {
  for (const cell of speedCells) {
    const id = cell.dataset.trafficSession;
    let upload = 0;
    let download = 0;
    let measured = false;
    for (const [child, counter] of Object.entries(current[id] || {})) {
      const before = previous[id]?.[child];
      if (!before || counter.upload < before.upload || counter.download < before.download) continue;
      upload += counter.upload - before.upload;
      download += counter.download - before.download;
      measured = true;
    }
    cell.querySelector('[data-upload]').textContent = measured ? formatSpeed(upload * 8 / seconds) : '—';
    cell.querySelector('[data-download]').textContent = measured ? formatSpeed(download * 8 / seconds) : '—';
  }
}

if (speedCells.length > 0) {
  let previous = {};
  let sampledAt = 0;
  async function sampleSpeeds() {
    try {
      if (document.hidden) {
        previous = {};
        return;
      }
      const response = await fetch('/sessions/traffic', { redirect: 'error' });
      if (!response.ok) throw new Error('Traffic request failed');
      const current = await response.json();
      const now = performance.now();
      showSpeeds(current, previous, (now - sampledAt) / 1000);
      previous = current;
      sampledAt = now;
    } catch {
      previous = {};
      showSpeeds({}, {}, 1);
    } finally {
      setTimeout(sampleSpeeds, 2000);
    }
  }
  sampleSpeeds();
}
const vpnMode = document.querySelector('select[name="VPN_MODE"]');
if (vpnMode) {
  const modeSections = document.querySelectorAll('[data-vpn-mode]');
  function showSelectedMode() {
    for (const section of modeSections) {
      section.hidden = section.dataset.vpnMode !== vpnMode.value;
    }
  }
  vpnMode.addEventListener('change', showSelectedMode);
  showSelectedMode();
}
const dnsRows = document.getElementById('dns-rows');
if (dnsRows) {
  const dnsTemplate = document.getElementById('dns-row-template');
  document.getElementById('add-dns').addEventListener('click', () => {
    const row = dnsTemplate.content.cloneNode(true);
    const input = row.querySelector('input');
    dnsRows.append(row);
    input.focus();
  });
  dnsRows.addEventListener('click', event => {
    const button = event.target.closest('[data-remove-dns]');
    if (!button) return;
    const row = button.closest('.dns-row');
    const next = row.nextElementSibling || row.previousElementSibling;
    if (next) {
      row.remove();
      next.querySelector('input').focus();
    } else {
      const input = row.querySelector('input');
      input.value = '';
      input.focus();
    }
  });
}
