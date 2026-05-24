const POLL_MS = 5000;
const BG_STATUS_POLL_MS = 30000;

const $sections = document.getElementById('sections');
const $vmDot = document.getElementById('vm-dot');
const $vmText = document.getElementById('vm-text');
const $ts = document.getElementById('ts');
const $bgOut = document.getElementById('bg-status-output');
const $bgTs  = document.getElementById('bg-status-ts');
const $bgBtn = document.getElementById('bg-status-refresh');
let bgInflight = false;

async function refresh() {
  try {
    const [status, commands] = await Promise.all([
      fetch('/api/status').then(r => r.json()),
      fetch('/api/commands').then(r => r.json())
    ]);
    renderStatus(status);
    renderCommands(commands);
  } catch (err) {
    $vmText.textContent = 'Error fetching status';
    $vmDot.className = 'dot dot-red';
    console.error(err);
  }
}

function renderStatus(s) {
  const vm = s.vm || {};
  if (vm.running) {
    $vmDot.className = 'dot dot-green';
    $vmText.textContent = `VM running (${vm.ip || 'no IP yet'})`;
  } else if (vm.exists) {
    $vmDot.className = 'dot dot-yellow';
    $vmText.textContent = `VM ${vm.state || 'unknown'}`;
  } else {
    $vmDot.className = 'dot dot-red';
    $vmText.textContent = 'VM not found';
  }
  $ts.textContent = `(refreshed ${new Date().toLocaleTimeString()})`;
}

function renderCommands(c) {
  const sections = c.sections || [];
  const html = sections.map(sec => {
    let lastSub = null;
    const items = sec.items.map(item => {
      let subHeader = '';
      if (item.sub && item.sub !== lastSub) {
        subHeader = `<h3 class="sub">${escapeHtml(item.sub)}</h3>`;
        lastSub = item.sub;
      } else if (!item.sub && lastSub) {
        lastSub = null;
      }
      const disabled = item.available ? '' : 'disabled';
      const title = item.available
        ? item.desc
        : `${item.desc}  —  Currently unavailable (VM not in required state).`;
      const confirmAttr = item.confirm ? ' data-confirm="true"' : '';
      const rowDisabled = item.available ? '' : ' data-disabled="true"';
      return `${subHeader}
        <div class="row"${confirmAttr}${rowDisabled} data-name="${escapeHtml(item.name)}" title="${escapeHtml(title)}">
          <span class="key">${escapeHtml(item.key)}.</span>
          <div class="info">
            <span class="name">${escapeHtml(item.name)}</span>
            <span class="desc">${escapeHtml(item.desc)}</span>
          </div>
          <button class="go" data-name="${escapeHtml(item.name)}" ${disabled}>Go</button>
        </div>`;
    }).join('');
    return `<section><h2>${escapeHtml(sec.name)}</h2><div class="grid">${items}</div></section>`;
  }).join('');
  $sections.innerHTML = html;

  $sections.querySelectorAll('button.go').forEach(btn => {
    btn.addEventListener('click', () => onExec(btn));
  });
}

async function onExec(btn) {
  const row = btn.closest('.row');
  const name = btn.dataset.name;
  const needsConfirm = row && row.dataset.confirm === 'true';
  if (needsConfirm) {
    const ok = confirm(`Run "${name}"?\n\nThis will affect the live server.`);
    if (!ok) return;
  }
  btn.disabled = true;
  const prev = btn.textContent;
  btn.textContent = 'Launching…';
  try {
    const res = await fetch(`/api/exec/${encodeURIComponent(name)}`, { method: 'POST' });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  } catch (err) {
    alert(`Failed to launch ${name}: ${err.message}`);
  } finally {
    setTimeout(() => {
      btn.textContent = prev;
      btn.disabled = false;
      refresh();
    }, 1500);
  }
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

async function refreshBgStatus({ fresh = false } = {}) {
  if (bgInflight) return;
  bgInflight = true;
  if (fresh) {
    $bgOut.textContent = 'Refreshing\u2026';
    $bgOut.classList.remove('bg-status-unavailable');
  }
  $bgBtn.disabled = true;
  try {
    const url = fresh ? '/api/bg-status?fresh=1' : '/api/bg-status';
    const r = await fetch(url);
    const data = await r.json();
    if (data.available) {
      $bgOut.textContent = data.output && data.output.length ? data.output : '(no output)';
      $bgOut.classList.remove('bg-status-unavailable');
    } else {
      $bgOut.textContent = data.reason || 'Status unavailable.';
      $bgOut.classList.add('bg-status-unavailable');
    }
    $bgTs.textContent = `(as of ${new Date().toLocaleTimeString()})`;
  } catch (err) {
    $bgOut.textContent = `Error fetching status: ${err.message}`;
    $bgOut.classList.add('bg-status-unavailable');
  } finally {
    bgInflight = false;
    $bgBtn.disabled = false;
  }
}

$bgBtn.addEventListener('click', () => refreshBgStatus({ fresh: true }));

refresh();
setInterval(refresh, POLL_MS);

refreshBgStatus();
setInterval(() => refreshBgStatus(), BG_STATUS_POLL_MS);
