for (const button of document.querySelectorAll('[data-open]')) {
  button.addEventListener('click', () => {
    const dialog = document.getElementById(button.dataset.open);
    const form = dialog.querySelector('form');
    form.reset();
    if (button.dataset.account) {
      dialog.querySelector('[data-account-label]').textContent = button.dataset.account;
      if (form.elements.username) form.elements.username.value = button.dataset.account;
    }
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

const restartButton = document.getElementById('restart-settings');
if (restartButton) {
  const status = document.getElementById('restart-status');
  restartButton.addEventListener('click', async () => {
    if (!window.confirm('重启会短暂断开所有 VPN 连接。现在重启？')) return;
    restartButton.disabled = true;
    status.textContent = '正在请求重启…';
    try {
      const response = await fetch('/settings/restart', { method: 'POST', redirect: 'manual' });
      if (response.type === 'opaqueredirect') {
        window.location.assign('/login');
        return;
      }
      if (response.status !== 202) {
        status.textContent = (await response.text()).trim();
        restartButton.disabled = false;
        return;
      }
    } catch {
      status.textContent = '未收到重启回执，请刷新页面确认服务状态。';
      restartButton.disabled = false;
      return;
    }

    status.textContent = '正在重启…';
    const deadline = Date.now() + 45000;
    while (Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 1500));
      try {
        const response = await fetch('/login', { redirect: 'manual', signal: AbortSignal.timeout(2000) });
        if (response.ok) {
          window.location.assign('/login');
          return;
        }
      } catch {
        // The listener is temporarily unavailable during restart.
      }
    }
    status.textContent = '等待服务恢复超时，请查看容器日志。';
  });
}

function formatSpeed(bitsPerSecond) {
  if (bitsPerSecond >= 1e9) return (bitsPerSecond / 1e9).toFixed(2) + ' Gbps';
  if (bitsPerSecond >= 1e6) return (bitsPerSecond / 1e6).toFixed(2) + ' Mbps';
  if (bitsPerSecond >= 1e3) return (bitsPerSecond / 1e3).toFixed(1) + ' Kbps';
  return Math.round(bitsPerSecond) + ' bps';
}

function showSpeeds(row, current, previous, seconds) {
  let upload = 0;
  let download = 0;
  let measured = false;
  for (const [child, counter] of Object.entries(current || {})) {
    const before = previous?.[child];
    if (!before || counter.upload < before.upload || counter.download < before.download) continue;
    upload += counter.upload - before.upload;
    download += counter.download - before.download;
    measured = true;
  }
  row.querySelector('[data-upload]').textContent = measured ? formatSpeed(upload * 8 / seconds) : '—';
  row.querySelector('[data-download]').textContent = measured ? formatSpeed(download * 8 / seconds) : '—';
}

const sessionList = document.getElementById('session-list');
if (sessionList) {
  const rowTemplate = document.getElementById('session-row-template');
  const empty = document.getElementById('session-empty');
  const count = document.getElementById('session-count');
  const error = document.getElementById('session-error');
  const rows = new Map(Array.from(sessionList.querySelectorAll('[data-traffic-session]'),
    row => [row.dataset.trafficSession, row]));
  let previous = new Map();
  let sampledAt = 0;
  let timer;
  let refreshing = false;

  async function refreshSessions() {
    if (document.hidden || refreshing) return;
    refreshing = true;
    try {
      const response = await fetch('/sessions/traffic', { redirect: 'error' });
      if (!response.ok) throw new Error('Traffic request failed');
      const sessions = await response.json();
      if (document.hidden) return;
      const now = performance.now();
      const current = new Map();
      for (const session of sessions) {
        let row = rows.get(session.id);
        if (!row) {
          row = rowTemplate.content.firstElementChild.cloneNode(true);
          row.dataset.trafficSession = session.id;
          sessionList.insertBefore(row, empty);
          rows.set(session.id, row);
        }
        row.querySelector('[data-session-account]').textContent = session.account;
        row.querySelector('[data-session-address]').textContent = session.address;
        row.querySelector('[data-session-peer]').textContent = session.peer;
        showSpeeds(row, session.traffic, previous.get(session.id), (now - sampledAt) / 1000);
        current.set(session.id, session.traffic);
      }
      for (const [id, row] of rows) {
        if (current.has(id)) continue;
        row.remove();
        rows.delete(id);
      }
      empty.hidden = sessions.length > 0;
      empty.firstElementChild.textContent = '当前没有在线连接。';
      count.textContent = sessions.length;
      error.hidden = true;
      previous = current;
      sampledAt = now;
    } catch {
      previous.clear();
      for (const row of rows.values()) showSpeeds(row, null, null, 1);
      empty.firstElementChild.textContent = '在线会话暂不可用。';
      count.textContent = '—';
      error.hidden = false;
    } finally {
      refreshing = false;
      if (!document.hidden) timer = setTimeout(refreshSessions, 2000);
    }
  }
  document.addEventListener('visibilitychange', () => {
    clearTimeout(timer);
    previous.clear();
    refreshSessions();
  });
  refreshSessions();
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
