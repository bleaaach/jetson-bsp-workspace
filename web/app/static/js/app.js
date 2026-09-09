/**
 * app.js — Jetson BSP Manager Web UI
 * All API calls, SSE streams, XTerm.js, and UI state management.
 */

"use strict";

// ─── State ────────────────────────────────────────────────────────────────
const state = {
  bspVersions: [],
  activeVersion: "R36.4.4",
  lastQuery: null,        // ModuleQueryResult
  lastBuildModule: "",
  lastBuildJobId: null,
  currentSshConn: null,   // {host, port, user}
  ws: null,               // WebSocket for terminal
  term: null,             // XTerm instance
  sseJobs: new Map(),     // jobId -> EventSource
  autoDownloads: new Map(),
  devices: [],
  buildConfigs: [],       // list of {name, bsp_version, suffix}
};

// ─── API helpers ──────────────────────────────────────────────────────────
async function apiGet(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r.json();
}

async function apiPost(url, body) {
  const r = await fetch(url, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r.json();
}

async function apiDelete(url) {
  const r = await fetch(url, {method: "DELETE"});
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r.json();
}

async function apiPut(url, body) {
  const r = await fetch(url, {
    method: "PUT",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r.json();
}

// ─── Init ────────────────────────────────────────────────────────────────
document.addEventListener("DOMContentLoaded", () => {
  setupNavigation();
  setupSearch();
  setupBuildForm();
  setupSshForm();
  loadDevices();
  loadBuildConfigs();
  loadJobs();
  refreshBspVersions();
  setupFirmwareSync();

  const sel = document.getElementById("globalBspVersion");
  sel.addEventListener("change", () => {
    state.activeVersion = sel.value;
    document.getElementById("buildBspVersion").value = sel.value;
  });
});

// ─── Navigation ──────────────────────────────────────────────────────────
function setupNavigation() {
  document.querySelectorAll(".nav-btn").forEach((btn) => {
    btn.addEventListener("click", () => switchTab(btn.dataset.tab));
  });
}

function switchTab(tab) {
  document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
  document.querySelector(`.nav-btn[data-tab="${tab}"]`)?.classList.add("active");

  document.querySelectorAll(".panel").forEach((p) => (p.dataset.active = "false"));
  // Panel id mapping (case-sensitive: ssh panel is panelSSH).
  const panelIds = {
    query: "panelQuery",
    thor: "panelThor",
    hybrid: "panelHybrid",
    build: "panelBuild",
    devices: "panelDevices",
    configs: "panelConfigs",
    ssh: "panelSSH",
    firmware: "panelFirmware",
  };
  const panel = document.getElementById(panelIds[tab]);
  if (panel) panel.dataset.active = "true";

  // Init Thor/Hybrid panel when first shown
  if (tab === "thor") {
    thorInit();
  } else if (tab === "hybrid") {
    hybridInit();
  }

  // Fit the terminal once its panel becomes visible.
  if (tab === "ssh" && state.term && state._fitAddon) {
    setTimeout(() => state._fitAddon.fit(), 50);
  }
}

// ─── BSP Versions ─────────────────────────────────────────────────────────
async function refreshBspVersions() {
  try {
    const data = await apiGet("/api/bsp/versions");
    state.bspVersions = data.versions || [];
    renderVersionList();
    renderVersionSelect();
  } catch (e) {
    console.error("Failed to load BSP versions", e);
  }
}

function renderVersionList() {
  const el = document.getElementById("versionList");
  if (!state.bspVersions.length) {
    el.innerHTML = `<div class="loading-spinner">无可用版本</div>`;
    return;
  }
  el.innerHTML = state.bspVersions.map((v) => {
    let tagClass, tagText;
    if (v.ready) { tagClass = "tag-ready"; tagText = "✓ 就绪"; }
    else if (v.downloaded) { tagClass = "tag-unpack"; tagText = "○ 未解压"; }
    else if (v.in_catalog) { tagClass = "tag-catalog"; tagText = "↓ 可下载"; }
    else { tagClass = "tag-unknown"; tagText = "? 未知"; }
    const size = v.total_size || "";
    const platform = v.platform || "";
    const jetpack = v.jetpack || "";
    const isActive = v.version === state.activeVersion ? "active" : "";
    const subHtml = (size || platform)
      ? `<div class="version-sub">`
        + (platform ? `<span class="sub-platform">${platform}</span>` : `<span class="sub-platform"></span>`)
        + (size ? `<span class="sub-size">${size}</span>` : ``)
        + `</div>`
      : "";
    return `
      <div class="version-item ${isActive}" onclick="selectBspVersion('${v.version}')"
           title="${v.kernel_path || (v.in_catalog ? 'NVIDIA 服务器可下载' : '未初始化')}">
        <div class="version-name">${v.version}</div>
        <div class="version-meta">
          <span class="version-tag ${tagClass}">${tagText}</span>
          ${jetpack ? `<span class="version-jetpack">${jetpack}</span>` : ""}
        </div>
        ${subHtml}
      </div>
    `;
  }).join("");
}

function renderVersionSelect() {
  const selects = [
    document.getElementById("globalBspVersion"),
    document.getElementById("buildBspVersion"),
  ];
  const html = state.bspVersions.map(
    (v) => `<option value="${v.version}">${v.version}${v.jetpack ? "  " + v.jetpack : ""}</option>`
  ).join("");

  selects.forEach((sel) => {
    if (!sel) return;
    const cur = sel.value;
    sel.innerHTML = html;
    if (html.includes(`value="${cur}"`)) sel.value = cur;
  });
}

function selectBspVersion(version) {
  state.activeVersion = version;
  document.getElementById("globalBspVersion").value = version;
  document.getElementById("buildBspVersion").value = version;
  renderVersionList();
  if (state.lastQuery) doQuery(state.lastQuery.module);
}

// ─── Download Modal ───────────────────────────────────────────────────────
function showDownloadModal() {
  document.getElementById("downloadModal").style.display = "flex";
  document.getElementById("dlProgress").style.display = "none";
  document.getElementById("dlStartBtn").disabled = false;
  loadOnlineVersions();
}

const dlCatalog = new Map();
const dlReachability = new Map();

async function loadOnlineVersions() {
  const sel = document.getElementById("dlVersion");
  sel.innerHTML = `<option value="">加载中...</option>`;
  sel.disabled = true;

  let catalog = [];
  try {
    const data = await apiGet("/api/bsp/versions/catalog");
    catalog = data.versions || [];
  } catch (e) { console.error("Failed to load BSP catalog", e); }

  const localByVer = new Map((state.bspVersions || []).map((v) => [v.version, v]));
  const versions = catalog.map((c) => {
    const local = localByVer.get(c.version) || {};
    return {...c, ready: !!local.ready, downloaded: !!local.downloaded};
  });

  dlCatalog.clear();
  versions.forEach((v) => dlCatalog.set(v.version, v));
  renderDownloadDropdown();

  apiGet("/api/bsp/versions/online")
    .then((data) => {
      const list = data.versions || [];
      dlReachability.clear();
      list.forEach((v) => dlReachability.set(v.version, !!v.available));
      renderDownloadDropdown();
    })
    .catch(() => {});

  sel.disabled = false;
}

function renderDownloadDropdown() {
  const sel = document.getElementById("dlVersion");
  if (!sel) return;
  const items = Array.from(dlCatalog.values());
  if (!items.length) { sel.innerHTML = `<option value="">无可用版本</option>`; return; }

  const rank = (v) => (v.ready ? 0 : v.downloaded ? 1 : 2);
  items.sort((a, b) => rank(a) - rank(b) || a.version.localeCompare(b.version));

  sel.innerHTML = items.map((v) => {
    let status;
    if (v.ready) status = "[✓就绪]";
    else if (v.downloaded) status = "[○未解压]";
    else if (dlReachability.has(v.version))
      status = dlReachability.get(v.version) ? "[✓可下载]" : "[⚠已下线]";
    else status = "[…检测中]";
    return `<option value="${v.version}">${status} ${v.version} — ${v.label}</option>`;
  }).join("");
}

function startDownload() {
  const version = document.getElementById("dlVersion").value;
  const init = document.getElementById("dlInit").checked;
  const btn = document.getElementById("dlStartBtn");
  const progress = document.getElementById("dlProgress");
  const log = document.getElementById("dlProgressLog");

  btn.disabled = true;
  progress.style.display = "flex";
  log.innerHTML = "";

  fetch("/api/bsp/download", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({version, init}),
  })
    .then((r) => r.json())
    .then(({job_id}) => {
      const es = new EventSource(`/api/bsp/download/stream/${job_id}`);
      const onMsg = (e) => {
        const msg = JSON.parse(e.data);
        const line = document.createElement("div");
        line.textContent = msg.message || msg.line || "";
        if (line.textContent) log.appendChild(line);
        log.scrollTop = log.scrollHeight;
      };
      es.addEventListener("progress", onMsg);
      es.addEventListener("log", onMsg);
      es.addEventListener("done", (e) => {
        es.close();
        const msg = JSON.parse(e.data);
        btn.disabled = false;
        const ok = msg.status === "ok" || msg.status === "success";
        const line = document.createElement("div");
        line.textContent = ok ? "✅ 完成" : "⚠️ 完成(有警告)";
        line.style.color = ok ? "var(--green)" : "var(--yellow)";
        log.appendChild(line);
        refreshBspVersions();
        loadJobs();
      });
      es.onerror = () => { es.close(); btn.disabled = false; };
    });
}

// ─── Search & Query ───────────────────────────────────────────────────────
function setupSearch() {
  const input = document.getElementById("searchInput");
  let timer = null;

  input.addEventListener("input", () => {
    clearTimeout(timer);
    const q = input.value.trim();
    if (!q) { hideSearchResults(); return; }
    timer = setTimeout(() => doQuickSearch(q), 280);
  });

  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      clearTimeout(timer);
      doQuery(input.value.trim());
    }
  });
}

function searchPreset(name) {
  const input = document.getElementById("searchInput");
  input.value = name;
  doQuickSearch(name);
  doQuery(name);
}

function hideSearchResults() {
  document.getElementById("searchResults").style.display = "none";
}

async function doQuickSearch(q) {
  try {
    const data = await apiGet(
      `/api/module/search?q=${encodeURIComponent(q)}&bsp_version=${state.activeVersion}`
    );
    renderQuickSearch(q, data.results || [], data.bsp_status);
  } catch (e) { console.error("Search failed", e); }
}

function renderQuickSearch(q, results, status) {
  const container = document.getElementById("searchResults");
  const list = document.getElementById("resultsList");
  const count = document.getElementById("resultsCount");

  if (status && status.state !== "ready") {
    count.textContent = `BSP ${state.activeVersion} 内核源码未就绪`;
    list.innerHTML = renderBspNotReadyHint(q, status.state);
    container.style.display = "block";
    if ((status.state === "downloaded" || status.state === "catalog") &&
        !state.autoDownloads.has(state.activeVersion)) {
      setTimeout(() => autoDownloadBsp(state.activeVersion, q, null, null, status.state), 0);
    } else if (state.autoDownloads.has(state.activeVersion)) {
      const entry = state.autoDownloads.get(state.activeVersion);
      const wrap = document.getElementById(entry.progressId);
      if (wrap) wrap.style.display = "block";
    }
    return;
  }

  if (!results.length) { container.style.display = "none"; return; }

  count.textContent = `找到 ${results.length} 个结果`;
  list.innerHTML = results.map((r) => `
    <div class="result-item" onclick="doQuery('${r.name}')">
      <span class="result-name">${r.name}</span>
      <span class="result-type ${r.type}">${r.type}</span>
      <span class="result-match">${r.match}</span>
    </div>
  `).join("");
  container.style.display = "block";
}

function renderBspNotReadyHint(q, bspState, opts = {}) {
  const ver = state.activeVersion;
  let stateLabel, actionLabel, helperText;
  if (bspState === "downloaded") {
    stateLabel = "已下载"; actionLabel = "⏳ 初始化源码";
    helperText = "源码包已就位，点击即可开始索引和解压。";
  } else if (bspState === "catalog") {
    stateLabel = "未下载"; actionLabel = "🚀 一键下载并初始化";
    helperText = "点击按钮，自动从 NVIDIA 下载源码包，完成后立即可搜索。";
  } else {
    stateLabel = "未在目录中"; actionLabel = "暂不可用";
    helperText = "该 BSP 版本暂不支持自动下载，请联系管理员。";
  }

  const canDownload = bspState === "downloaded" || bspState === "catalog";
  const safeVer = ver.replace(/[^A-Za-z0-9]/g, "_");
  const safeQ = (q || "auto").replace(/[^A-Za-z0-9]/g, "_").slice(0, 32);
  const progressId = `bspDlProgress-${safeVer}-${safeQ}`;
  const btnId = `bspDlBtn-${safeVer}-${safeQ}`;

  return `
    <div class="bsp-hint-card">
      <div class="bsp-hint-header">
        <span class="bsp-hint-icon">⚠️</span>
        <div class="bsp-hint-title"><strong>${ver}</strong> 内核源码 ${stateLabel}</div>
      </div>
      <p class="bsp-hint-text">${helperText} ${q ? `搜索 “<code>${q}</code>” 需要先准备好 ${ver} 内核源码。` : ""}</p>
      <div class="bsp-hint-actions">
        ${canDownload
          ? `<button class="btn btn-primary btn-sm" id="${btnId}"
                 onclick="autoDownloadBsp('${ver}', document.getElementById('searchInput')?.value || '', '${progressId}', '${btnId}', '${bspState}')">${actionLabel}</button>`
          : `<button class="btn btn-ghost btn-sm" disabled>${actionLabel}</button>`}
        <button class="btn btn-ghost btn-sm" onclick="closeModal('downloadModal'); showDownloadModal()">📦 手动管理…</button>
      </div>
      <div class="bsp-hint-progress" id="${progressId}" style="display:none;">
        <div class="progress-bar"><div class="progress-fill"></div></div>
        <div class="progress-log"></div>
      </div>
    </div>
  `;
}

function autoDownloadBsp(version, originalQuery, progressId, btnId, bspState) {
  if (!progressId || !btnId) {
    const safeVer = version.replace(/[^A-Za-z0-9]/g, "_");
    const safeQ = (originalQuery || "auto").replace(/[^A-Za-z0-9]/g, "_").slice(0, 32);
    progressId = `bspDlProgress-${safeVer}-${safeQ}`;
    btnId = `bspDlBtn-${safeVer}-${safeQ}`;
  }
  const isInitOnly = bspState === "downloaded";
  const startMsg = isInitOnly
    ? `⏳ 正在提交 ${version} 初始化任务…`
    : `⏳ 正在提交 ${version} 下载任务…`;

  if (state.autoDownloads.has(version)) {
    const wrap = document.getElementById(progressId);
    if (wrap) wrap.style.display = "block";
    return;
  }
  const wrap = document.getElementById(progressId);
  const btn = document.getElementById(btnId);
  if (!wrap) return;
  const log = wrap.querySelector(".progress-log");

  wrap.style.display = "block";
  if (btn) btn.disabled = true;
  log.innerHTML = "";
  appendLine(log, startMsg, "info");

  fetch("/api/bsp/download", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({version, init: true}),
  })
    .then((r) => r.json())
    .then(({job_id}) => {
      if (!job_id) throw new Error("无 job_id");
      const es = new EventSource(`/api/bsp/download/stream/${job_id}`);
      state.autoDownloads.set(version, {jobId: job_id, es, progressId, btnId});
      appendLine(log, `📡 任务已启动 (job=${job_id})`, "info");

      function handleSseEvent(e) {
        const msg = JSON.parse(e.data);
        const text = msg.message || msg.line || "";
        if (/已存在|already|exists/i.test(text)) appendLine(log, `📦 ${text}，开始解压…`, "info");
        else if (/解压|extract|Extract|解包/i.test(text)) appendLine(log, `📦 ${text}`, "info");
        else if (/下载|Downloading|fetching|开始下载/i.test(text)) appendLine(log, `⬇️  ${text}`, "info");
        else if (/完成|finished|success/i.test(text)) appendLine(log, `✅ ${text}`, "ok");
        else appendLine(log, text, "muted");
      }

      es.addEventListener("progress", handleSseEvent);
      es.addEventListener("log", handleSseEvent);
      es.addEventListener("done", (e) => {
        es.close();
        state.autoDownloads.delete(version);
        const msg = JSON.parse(e.data);
        appendLine(log, msg.message || "🎉 内核源码已就绪，重新搜索中…", "ok");
        refreshBspVersions();
        loadJobs();
        setTimeout(() => {
          if (originalQuery) doQuery(originalQuery);
          else {
            const input = document.getElementById("searchInput");
            if (input.value.trim()) doQuickSearch(input.value.trim());
          }
          if (btn) btn.disabled = false;
        }, 800);
      });
      es.onerror = () => {
        es.close();
        state.autoDownloads.delete(version);
        appendLine(log, "❌ 连接中断，请查看服务日志", "err");
        if (btn) btn.disabled = false;
      };
    })
    .catch((e) => {
      appendLine(log, `❌ ${e.message}`, "err");
      if (btn) btn.disabled = false;
    });
}

function appendLine(log, text, kind = "muted") {
  if (!text) return;
  const line = document.createElement("div");
  line.className = `hint-log-line hint-${kind}`;
  line.textContent = text;
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
}

async function doQuery(module) {
  if (!module) return;
  const input = document.getElementById("searchInput");
  input.value = module;

  hideSearchResults();
  showModuleDetailLoading();

  try {
    const data = await apiPost("/api/module/query", {
      module,
      bsp_version: state.activeVersion,
    });
    state.lastQuery = data;
    renderModuleDetail(data);
  } catch (e) {
    console.error("Query failed", e);
    showModuleDetailError(e.message);
  }
}

function showModuleDetailLoading() {
  document.getElementById("moduleDetailEmpty").style.display = "none";
  const content = document.getElementById("moduleDetailContent");
  content.style.display = "block";
  content.innerHTML = `<div class="loading-spinner" style="padding:40px">查询中...</div>`;
}

function showModuleDetailError(msg) {
  const content = document.getElementById("moduleDetailContent");
  content.innerHTML = `<div class="card"><div class="card-body" style="color:var(--red)">❌ ${msg}</div></div>`;
}

function renderModuleDetail(d) {
  const content = document.getElementById("moduleDetailContent");
  document.getElementById("moduleDetailEmpty").style.display = "none";
  content.style.display = "block";

  if (!d.available) {
    content.innerHTML = `
      <div class="card">
        <div class="card-header"><span class="card-title">⚠️ 找不到模块</span></div>
        <div class="card-body"><p style="color:var(--text-secondary)">${d.summary}</p></div>
      </div>
    `;
    return;
  }

  const src = d.source || {};
  const cfg = d.config_status || {};
  const kos = d.compiled_kos || [];

  // CONFIG 默认值徽章: Seeed BSP / NVIDIA 官方 / 实际构建
  const defLabel = (v) => {
    const map = {
      y: {cls: "builtin", text: "=y 已内置"},
      m: {cls: "module", text: "=m 可编译"},
      n: {cls: "disabled", text: "=n 禁用"},
      "not set": {cls: "disabled", text: "未启用"},
      "": {cls: "unknown", text: "(defconfig 未显式)"},
    };
    const s = map[v] || {cls: "unknown", text: v || "?"};
    return `<span class="status-badge ${s.cls}">${s.text}</span>`;
  };
  const bd = src.bsp_default || "";
  const od = src.official_default || "";
  const bv = src.build_value || "";
  const rk = src.rootfs_ko || "";           // rootfs 部署的 .ko (硬标准)
  const inTree = src.in_tree !== false;     // 内核树内是否有源码

  // 配置块: 树里无源码时 config_name 为空, 自然隐藏
  let bspDefaultHtml = "";
  if (src.kconfig_name) {
    bspDefaultHtml = `
      <span class="info-label">Seeed BSP 配置</span>
      <span class="info-value">${defLabel(bd)}</span>
      <span class="info-label">NVIDIA 官方配置</span>
      <span class="info-value">${defLabel(od)}</span>
      ${bv ? `<span class="info-label">本机构建实际</span>
      <span class="info-value">${defLabel(bv)}</span>` : ""}
    `;
  }

  const ORIGIN_LABEL = {
    "nvidia-official": {cls: "origin-nvidia", text: "NVIDIA 官方"},
    "seeed-modified":  {cls: "origin-seeed", text: "Seeed 修改"},
    "seeed-only":      {cls: "origin-seeed-only", text: "Seeed 独有"},
    "unknown":         {cls: "origin-unknown", text: "未知"},
  };

  const srcFiles = src.files || [];
  const origins = src.origins || {};

  // 出处汇总徽章 (verdict 细节与模块卡片标题共用)
  let originBadge = "";
  if (srcFiles.length && origins) {
    const kinds = srcFiles.map((f) => origins[f]).filter(Boolean);
    if (kinds.every((k) => k === "nvidia-official")) {
      originBadge = `<span class="status-badge builtin">NVIDIA 官方源码</span>`;
    } else if (kinds.some((k) => k === "seeed-only")) {
      originBadge = `<span class="status-badge seeed">含 Seeed 独有驱动</span>`;
    } else if (kinds.some((k) => k === "seeed-modified")) {
      originBadge = `<span class="status-badge seeed">Seeed 修改驱动</span>`;
    }
  }

  // 四分支归属判定 (优先级: 事实 → 推断):
  // 1. rootfs 有 .ko → BSP 固件已含
  // 2. 内核树自带源码 → 可直接编译
  // 3. 树无源码 + 有产物 → 外部源码/自建编译
  // 4. 树无源码 + 无产物 → 需外部获取/自建
  let verdictHtml = "";
  if (rk) {
    verdictHtml = `
      <span class="info-label" style="color:var(--green)">✅ BSP 固件已含</span>
      <span class="info-value" style="color:var(--green)">rootfs: ${rk}，设备直接可用</span>
    `;
  } else if (inTree) {
    const cfgOn = bd === "y" || bd === "m" || od === "y" || od === "m";
    verdictHtml = `
      <span class="info-label" style="color:var(--blue)">🌲 内核树自带源码，可直接编译</span>
      <span class="info-value" style="color:var(--blue)">${originBadge || "源码位于内核树内"}</span>
      <span class="info-label">Seeed/NVIDIA 配置</span>
      <span class="info-value">${defLabel(bd)} ${defLabel(od)} · 本机 ${kos.length} 个 .ko</span>
      <span class="info-label">固件</span>
      <span class="info-value">BSP 固件不含 .ko（rootfs 为空），需自行编译并安装${!cfgOn && src.kconfig_name ? `<span style="color:var(--yellow)">，但 defconfig 未开启，编译前需先开 ${src.kconfig_name}</span>` : ""}</span>
    `;
  } else if (kos.length) {
    verdictHtml = `
      <span class="info-label" style="color:var(--blue)">🛠️ 内核树无此驱动源码 → 外部源码/自建编译</span>
      <span class="info-value" style="color:var(--blue)">本机已有 ${kos.length} 个 .ko（自建脚本产出，如 build-rtw89-8852be.sh）</span>
    `;
  } else {
    verdictHtml = `
      <span class="info-label" style="color:var(--yellow)">内核树无源码且无产物</span>
      <span class="info-value" style="color:var(--yellow)">需外部获取源码或自建（如 ~/rtw89-src 之类外部目录）</span>
    `;
  }

  let statusBadge = "";
  if (cfg.value) {
    const map = {
      y: {cls: "builtin", text: `内置 (=y)`},
      m: {cls: "module", text: `可编译 (=m)`},
      n: {cls: "disabled", text: `已禁用 (=n)`},
      "not set": {cls: "disabled", text: "未启用"},
    };
    const s = map[cfg.value] || {cls: "unknown", text: cfg.value};
    statusBadge = `<span class="status-badge ${s.cls}">${s.text}</span>`;
  }

  const sourceHtml = srcFiles.length
    ? srcFiles.map((f) => {
        const og = ORIGIN_LABEL[origins[f]] || ORIGIN_LABEL["unknown"];
        return `<div class="file-path"><span class="origin-badge ${og.cls}">${og.text}</span>${f}</div>`;
      }).join("")
    : `<span style="color:var(--text-muted)">未找到源文件</span>`;

  const koHtml = kos.length
    ? kos.map((k) => `
        <div class="ko-item">
          <span class="ko-name">${k.path.split("/").pop()}</span>
          <span class="ko-size">${k.size}</span>
          ${k.vermagic ? `<span style="font-size:11px;color:var(--text-muted)">${k.vermagic}</span>` : ""}
        </div>
      `).join("")
    : `<span style="color:var(--text-muted);font-size:12px">暂无已编译的 .ko</span>`;

  content.innerHTML = `
    <div class="card">
      <div class="card-header">
        <span class="card-title">📦 模块: ${d.module}</span>
        ${originBadge}
        ${statusBadge}
      </div>
      <div class="card-body">
        <div class="info-grid">
          <span class="info-label">BSP 版本</span>
          <span class="info-value">${d.bsp_version}</span>
          ${cfg.config_name ? `<span class="info-label">CONFIG</span><span class="info-value" style="color:var(--accent)">${cfg.config_name}</span>` : ""}
          ${cfg.build_config ? `<span class="info-label">构建配置</span><span class="info-value">${cfg.build_config}</span>` : ""}
          ${cfg.raw_line ? `<span class="info-label">.config 行</span><span class="info-value" style="font-size:11px">${cfg.raw_line}</span>` : ""}
          <span class="info-label">结论</span>
          <span class="info-value">${d.summary}</span>
          ${verdictHtml}
      </div>
      </div>
    </div>

    ${src.kconfig_name ? `
    <div class="card">
      <div class="card-header"><span class="card-title">⚙️ Kconfig</span></div>
      <div class="card-body">
        <div class="info-grid">
          <span class="info-label">配置项</span>
          <span class="info-value" style="color:var(--accent)">${src.kconfig_name}</span>
          ${bspDefaultHtml}
          ${src.kconfig_file ? `<span class="info-label">文件</span><span class="info-value">${src.kconfig_file}</span>` : ""}
          ${src.extra_configs && src.extra_configs.length ? `<span class="info-label">子配置</span><span class="info-value">${src.extra_configs.join(", ")}</span>` : ""}
        </div>
        ${src.makefile_rules && src.makefile_rules.length ? `
        <div style="margin-top:10px">
          <div class="info-label" style="margin-bottom:4px">Makefile 规则</div>
          ${src.makefile_rules.slice(0, 5).map((r) => `<div class="file-path" style="font-size:11px">${r}</div>`).join("")}
        </div>
        ` : ""}
      </div>
    </div>
    ` : ""}

    <div class="card">
      <div class="card-header"><span class="card-title">📄 源码文件</span></div>
      <div class="card-body"><div class="file-list">${sourceHtml}</div></div>
    </div>

    <div class="card">
      <div class="card-header"><span class="card-title">🖥️ 已编译的 .ko</span></div>
      <div class="card-body"><div class="ko-list">${koHtml}</div></div>
    </div>

    <div class="action-row">
      <button class="btn btn-primary btn-sm" onclick="buildFromQuery('${d.module}')">⚡ 编译</button>
      ${kos.length ? `<button class="btn btn-success btn-sm" onclick="pushFromQuery('${d.module}')">📤 推送</button>` : ""}
      <button class="btn btn-ghost btn-sm" onclick="doQuery('${d.module}')">🔄 刷新</button>
    </div>
  `;
}

// ─── Build ────────────────────────────────────────────────────────────────
function setupBuildForm() {
  const input = document.getElementById("buildModuleName");
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") startBuild();
  });
}

function openQueryInBuild() {
  if (!state.lastQuery) { toast("请先在查询区搜索一个模块", "info"); return; }
  const input = document.getElementById("buildModuleName");
  input.value = state.lastQuery.module;
  document.getElementById("buildBspVersion").value = state.activeVersion;
  if (state.lastQuery.source?.kconfig_name) {
    const cfg = state.lastQuery.source.kconfig_name.replace("CONFIG_", "");
    document.getElementById("buildConfigSuffix").value = cfg;
  }
  switchTab("build");
}

function buildFromQuery(module) {
  document.getElementById("buildModuleName").value = module;
  switchTab("build");
  if (state.lastQuery?.source?.kconfig_name) {
    const cfg = state.lastQuery.source.kconfig_name.replace("CONFIG_", "");
    document.getElementById("buildConfigSuffix").value = cfg;
  }
}

function startBuild() {
  const module = document.getElementById("buildModuleName").value.trim();
  if (!module) { toast("请输入模块名", "error"); return; }
  const bspVersion = document.getElementById("buildBspVersion").value;
  const configSuffix = document.getElementById("buildConfigSuffix").value.trim();
  const seedConfig = document.getElementById("buildSeedConfig").value;

  state.lastBuildModule = module;

  const outputEl = document.getElementById("buildOutput");
  outputEl.style.display = "block";
  const termEl = document.getElementById("buildTerminal");
  termEl.innerHTML = "";
  document.getElementById("buildStatusBadge").className = "build-status-badge running";
  document.getElementById("buildStatusBadge").textContent = "⏳ 编译中";
  document.getElementById("buildMeta").textContent = `${module} · ${bspVersion}`;
  document.getElementById("koListSection").style.display = "none";

  const params = new URLSearchParams({bsp_version: bspVersion, config_suffix: configSuffix});
  if (seedConfig) params.set("seed_config", seedConfig);

  fetch(`/api/build/${encodeURIComponent(module)}?${params.toString()}`)
    .then((r) => r.json())
    .then(({job_id}) => {
      state.lastBuildJobId = job_id;
      const es = new EventSource(`/api/build/stream/${job_id}`);
      es.addEventListener("log", (e) => {
        appendBuildLog(JSON.parse(e.data).line || "");
      });
      es.addEventListener("done", (e) => {
        es.close();
        const msg = JSON.parse(e.data);
        const ok = msg.status === "success";
        const badge = document.getElementById("buildStatusBadge");
        badge.className = `build-status-badge ${ok ? "success" : "error"}`;
        badge.textContent = ok ? "✅ 编译成功" : "❌ 编译失败";
        if (ok) {
          appendBuildLog("--- 编译完成 ---");
          loadCompiledKos(module);
        }
        loadJobs();
        toast(ok ? "编译成功!" : "编译失败", ok ? "success" : "error");
      });
      es.onerror = () => { es.close(); appendBuildLog("SSE 连接错误"); };
    })
    .catch((e) => { appendBuildLog(`错误: ${e.message}`); });
}

function appendBuildLog(line) {
  const termEl = document.getElementById("buildTerminal");
  const isError = /error|fail|✗|not found|cannot/i.test(line);
  const isOk = /✓|success|done|compiled|built/i.test(line);
  const isWarn = /warn|⚠/i.test(line);
  let cls = "";
  if (isError) cls = "error";
  else if (isOk) cls = "ok";
  else if (isWarn) cls = "warn";
  const span = document.createElement("span");
  span.className = `log-line ${cls}`;
  span.textContent = line;
  termEl.appendChild(span);
  termEl.appendChild(document.createElement("br"));
  termEl.scrollTop = termEl.scrollHeight;
}

function loadCompiledKos(module) {
  apiPost("/api/module/query", {module, bsp_version: state.activeVersion})
    .then((d) => {
      state.lastQuery = d;
      const kos = d.compiled_kos || [];
      if (kos.length) {
        const section = document.getElementById("koListSection");
        const list = document.getElementById("koList");
        section.style.display = "block";
        list.innerHTML = kos.map((k) => `
          <div class="ko-item">
            <span class="ko-name">${k.path.split("/").pop()}</span>
            <span class="ko-size">${k.size}</span>
          </div>
        `).join("");
      }
    });
}

function clearBuildOutput() {
  document.getElementById("buildTerminal").innerHTML = "";
  document.getElementById("buildOutput").style.display = "none";
  document.getElementById("koListSection").style.display = "none";
}

// ─── Devices ──────────────────────────────────────────────────────────────
async function loadDevices() {
  try {
    const data = await apiGet("/api/devices");
    state.devices = data.devices || [];
    renderDevices();
    renderDeviceSelects();
  } catch (e) {
    console.error("Failed to load devices", e);
  }
}

function renderDevices() {
  const el = document.getElementById("devicesList");
  if (!state.devices.length) {
    el.innerHTML = `<div class="loading-spinner">暂无设备，请在上方添加</div>`;
    return;
  }
  el.innerHTML = state.devices.map((d) => `
    <div class="device-item">
      <div class="device-info">
        <label class="checkbox-label">
          <input type="checkbox" class="device-check" value="${d.id}" />
        </label>
        <span class="device-name">${d.name}</span>
        <span class="device-address">${d.user}@${d.host}:${d.port}</span>
        ${d.note ? `<span class="device-note">${d.note}</span>` : ""}
        ${d.key_path ? `<span class="device-note">🔑 ${d.key_path}</span>` : ""}
      </div>
      <div class="device-actions">
        <button class="btn btn-sm btn-ghost" onclick="testDevice(${d.id})">测连</button>
        <button class="btn btn-sm btn-ghost" onclick="connectDevice(${d.id})">终端</button>
        <button class="btn btn-sm btn-ghost" onclick="editDevice(${d.id})">编辑</button>
        <button class="btn btn-sm btn-danger" onclick="deleteDevice(${d.id})">删除</button>
      </div>
    </div>
  `).join("");
}

function renderDeviceSelects() {
  const opts = state.devices.map((d) =>
    `<option value="${d.id}">${d.name} (${d.host})</option>`
  ).join("");
  document.getElementById("sshDevice").innerHTML = `<option value="">手动输入…</option>` + opts;
  document.getElementById("pushDevice").innerHTML = `<option value="">手动输入…</option>` + opts;
}

function resetDeviceForm() {
  document.getElementById("devEditId").value = "";
  document.getElementById("devName").value = "";
  document.getElementById("devHost").value = "";
  document.getElementById("devPort").value = "22";
  document.getElementById("devUser").value = "nvidia";
  document.getElementById("devKeyPath").value = "";
  document.getElementById("devNote").value = "";
}

function editDevice(id) {
  const d = state.devices.find((x) => x.id === id);
  if (!d) return;
  document.getElementById("devEditId").value = d.id;
  document.getElementById("devName").value = d.name;
  document.getElementById("devHost").value = d.host;
  document.getElementById("devPort").value = d.port;
  document.getElementById("devUser").value = d.user;
  document.getElementById("devKeyPath").value = d.key_path || "";
  document.getElementById("devNote").value = d.note || "";
}

async function saveDevice() {
  const id = document.getElementById("devEditId").value;
  const body = {
    name: document.getElementById("devName").value.trim(),
    host: document.getElementById("devHost").value.trim(),
    port: parseInt(document.getElementById("devPort").value) || 22,
    user: document.getElementById("devUser").value.trim() || "nvidia",
    key_path: document.getElementById("devKeyPath").value.trim(),
    note: document.getElementById("devNote").value.trim(),
  };
  if (!body.name || !body.host) { toast("请填写名称和主机", "error"); return; }
  try {
    if (id) await apiPut(`/api/devices/${id}`, body);
    else await apiPost("/api/devices", body);
    resetDeviceForm();
    loadDevices();
    toast("已保存设备", "success");
  } catch (e) { toast(`保存失败: ${e.message}`, "error"); }
}

async function deleteDevice(id) {
  if (!confirm("确认删除该设备?")) return;
  try {
    await apiDelete(`/api/devices/${id}`);
    loadDevices();
  } catch (e) { toast(`删除失败: ${e.message}`, "error"); }
}

async function testDevice(id) {
  const d = state.devices.find((x) => x.id === id);
  if (!d) return;
  const password = prompt(`输入 ${d.name} (${d.host}) 的密码 (可选，仅本次):`) || "";
  const r = await apiPost(`/api/devices/${id}/test`, {
    password, key_path: d.key_path,
  });
  if (r.online) toast(`${d.name}: ${r.kernel_version}`, "success");
  else toast(`${d.name}: ${r.error || "连接失败"}`, "error");
}

async function testDeviceFromForm(d) {
  const password = document.getElementById("sshPassword").value;
  const r = await apiPost("/api/devices/test", {
    host: d.host, port: d.port, user: d.user,
    password, key_path: d.key_path,
  });
  return r;
}

// ─── Batch Push ───────────────────────────────────────────────────────────
function startBatchPush() {
  const module = document.getElementById("batchModule").value.trim();
  const ids = state.devices
    .filter((d, i) => document.querySelectorAll(".device-check")[i]?.checked)
    .map((d) => d.id);
  const password = document.getElementById("batchPassword").value;
  const keyPath = document.getElementById("batchKeyPath").value.trim();
  const testLoad = document.getElementById("batchTestLoad").checked;

  if (!module) { toast("请输入模块名", "error"); return; }
  if (!ids.length) { toast("请先勾选设备", "error"); return; }

  const progress = document.getElementById("batchProgress");
  const log = document.getElementById("batchProgressLog");
  progress.style.display = "flex";
  log.innerHTML = "";

  fetch("/api/push/batch", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({module, device_ids: ids, password, key_path: keyPath, test_load: testLoad}),
  })
    .then((r) => r.json())
    .then(({job_id}) => {
      const es = new EventSource(`/api/push/batch/stream/${job_id}`);
      es.addEventListener("log", (e) => appendProgressLine(log, JSON.parse(e.data).line || ""));
      es.addEventListener("done", (e) => {
        es.close();
        const msg = JSON.parse(e.data);
        const ok = msg.status === "ok";
        appendProgressLine(log, msg.message || "完成", ok ? "ok" : "err");
        loadJobs();
      });
      es.onerror = () => es.close();
    });
}

function appendProgressLine(log, text, kind = "") {
  const line = document.createElement("div");
  line.textContent = text;
  if (kind === "err") line.style.color = "var(--red)";
  else if (kind === "ok") line.style.color = "var(--green)";
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
}

// ─── Jobs History ─────────────────────────────────────────────────────────
async function loadJobs() {
  try {
    const data = await apiGet("/api/jobs");
    const el = document.getElementById("jobsList");
    const jobs = data.jobs || [];
    if (!jobs.length) { el.innerHTML = `<span class="text-muted">暂无记录</span>`; return; }
    el.innerHTML = jobs.map((j) => {
      const d = new Date(j.created_at * 1000);
      const time = `${d.toLocaleDateString()} ${d.toLocaleTimeString()}`;
      const cls = j.status === "ok" ? "job-ok" : j.status === "error" ? "job-err" : "job-running";
      const label = {"build": "编译", "push": "推送", "download": "下载"}[j.kind] || j.kind;
      return `
        <div class="job-item ${cls}">
          <span class="job-kind">${label}</span>
          <span class="job-target">${j.target}</span>
          <span class="job-status">${j.status === "ok" ? "✓" : j.status === "error" ? "✗" : "…"}</span>
          <span class="job-message">${j.message || ""}</span>
          <span class="job-time">${time}</span>
        </div>
      `;
    }).join("");
  } catch (e) { console.error("Failed to load jobs", e); }
}

// ─── Config Editor ────────────────────────────────────────────────────────
async function loadBuildConfigs() {
  try {
    const data = await apiGet("/api/configs");
    state.buildConfigs = data.configs || [];
    renderBuildConfigs();
  } catch (e) { console.error("Failed to load configs", e); }
}

function renderBuildConfigs() {
  const select = document.getElementById("cfgSelect");
  select.innerHTML = state.buildConfigs.map((c) =>
    `<option value="${c.name}">${c.name}${c.kernel_ready ? "" : " (无源码)"}</option>`
  ).join("") || `<option value="">无构建配置</option>`;

  const seedSel = document.getElementById("buildSeedConfig");
  seedSel.innerHTML = `<option value="">自动选择</option>` + state.buildConfigs.map((c) =>
    `<option value="${c.name}">${c.name}</option>`
  ).join("");
}

function onCfgSelect() { /* placeholder for future detail load */ }

async function readConfigKey() {
  const cfgName = document.getElementById("cfgSelect").value;
  const key = document.getElementById("cfgName").value.trim();
  if (!cfgName || !key) { toast("请填写构建配置和 CONFIG 名", "error"); return; }
  try {
    const data = await apiGet(`/api/configs/${cfgName}/key?config=${encodeURIComponent(key)}`);
    document.getElementById("cfgStatus").style.display = "block";
    document.getElementById("cfgCurrent").innerHTML =
      `<span class="status-badge ${cfgBadgeCls(data.value)}">${data.value || "(未找到)"}</span>`;
    document.getElementById("cfgSaveResult").innerHTML = "";
  } catch (e) { toast(`读取失败: ${e.message}`, "error"); }
}

function cfgBadgeCls(value) {
  if (value === "y") return "builtin";
  if (value === "m") return "module";
  if (value === "n" || value === "not set") return "disabled";
  return "unknown";
}

async function setConfigKey(value) {
  const cfgName = document.getElementById("cfgSelect").value;
  const key = document.getElementById("cfgName").value.trim();
  if (!cfgName || !key) { toast("请填写构建配置和 CONFIG 名", "error"); return; }
  try {
    const data = await apiPost(`/api/configs/${cfgName}/key`, {
      config_name: key,
      value,
    });
    if (data.ok) {
      document.getElementById("cfgCurrent").innerHTML =
        `<span class="status-badge ${cfgBadgeCls(data.value)}">${data.value}</span>`;
      document.getElementById("cfgSaveResult").innerHTML =
        `<span style="color:var(--green)">✓ 已保存并重新 olddefconfig</span>`;
      toast(`已设 ${data.config_name}=${data.value}`, "success");
    } else {
      document.getElementById("cfgSaveResult").innerHTML =
        `<span style="color:var(--red)">✗ ${data.error || "保存失败"}</span>`;
      toast("保存失败", "error");
    }
  } catch (e) {
    document.getElementById("cfgSaveResult").innerHTML = `<span style="color:var(--red)">✗ ${e.message}</span>`;
  }
}

// ─── Push ─────────────────────────────────────────────────────────────────
function pushFromQuery(module) {
  document.getElementById("pushModule").value = module;
  switchTab("devices");
  openPushModal();
}

function onPushDeviceSelect() {
  const id = parseInt(document.getElementById("pushDevice").value);
  const d = state.devices.find((x) => x.id === id);
  if (d) {
    document.getElementById("pushHost").value = d.host;
    document.getElementById("pushPort").value = d.port;
    document.getElementById("pushUser").value = d.user;
    document.getElementById("pushKeyPath").value = d.key_path || "";
  }
}

function openPushModal() {
  const module = document.getElementById("buildModuleName")?.value ||
                 state.lastBuildModule ||
                 state.lastQuery?.module;
  document.getElementById("pushModule").value = module || "";
  document.getElementById("pushProgress").style.display = "none";
  document.getElementById("pushStartBtn").disabled = false;
  document.getElementById("pushDevice").value = "";
  document.getElementById("pushHost").value = "";
  document.getElementById("pushPort").value = "22";
  document.getElementById("pushUser").value = "nvidia";
  document.getElementById("pushKeyPath").value = "";
  if (state.currentSshConn) {
    document.getElementById("pushHost").value = state.currentSshConn.host;
    document.getElementById("pushPort").value = state.currentSshConn.port || 22;
    document.getElementById("pushUser").value = state.currentSshConn.user || "nvidia";
  }
  document.getElementById("pushModal").style.display = "flex";
}

function startPush() {
  const module = document.getElementById("pushModule").value.trim();
  const host = document.getElementById("pushHost").value.trim();
  const port = parseInt(document.getElementById("pushPort").value) || 22;
  const user = document.getElementById("pushUser").value.trim() || "nvidia";
  const keyPath = document.getElementById("pushKeyPath").value.trim();
  const password = document.getElementById("pushPassword").value;
  const testLoad = document.getElementById("pushTestLoad").checked;

  if (!module || !host) { toast("请填写模块名和主机", "error"); return; }

  const btn = document.getElementById("pushStartBtn");
  const progress = document.getElementById("pushProgress");
  const log = document.getElementById("pushProgressLog");

  btn.disabled = true;
  progress.style.display = "flex";
  log.innerHTML = "";

  fetch("/api/ssh/push", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({module, host, port, user, key_path: keyPath, password, test_load: testLoad}),
  })
    .then((r) => r.json())
    .then(({job_id}) => {
      const es = new EventSource(`/api/ssh/stream/${job_id}`);
      es.addEventListener("log", (e) => appendProgressLine(log, JSON.parse(e.data).line || ""));
      es.addEventListener("done", (e) => {
        es.close();
        btn.disabled = false;
        const msg = JSON.parse(e.data);
        const ok = msg.status === "ok";
        appendProgressLine(log, msg.message || (ok ? "完成" : "失败"), ok ? "ok" : "err");
        toast(msg.message || (ok ? "推送完成" : "推送失败"), ok ? "success" : "error");
        loadJobs();
      });
      es.onerror = () => { es.close(); btn.disabled = false; };
    });
}

// ─── SSH Terminal ────────────────────────────────────────────────────────
function setupSshForm() {
  document.getElementById("sshHost").addEventListener("keydown", (e) => {
    if (e.key === "Enter") openSshSession();
  });
}

function onSshDeviceSelect() {
  const id = parseInt(document.getElementById("sshDevice").value);
  const d = state.devices.find((x) => x.id === id);
  if (d) {
    document.getElementById("sshHost").value = d.host;
    document.getElementById("sshPort").value = d.port;
    document.getElementById("sshUser").value = d.user;
    document.getElementById("sshKeyPath").value = d.key_path || "";
  }
}

async function testConnection() {
  const host = document.getElementById("sshHost").value.trim();
  const port = parseInt(document.getElementById("sshPort").value) || 22;
  const user = document.getElementById("sshUser").value.trim() || "nvidia";
  const password = document.getElementById("sshPassword").value;
  const keyPath = document.getElementById("sshKeyPath").value.trim();

  const card = document.getElementById("connStatusCard");
  card.style.display = "flex";

  try {
    const data = await apiPost("/api/devices/test", {host, port, user, password, key_path: keyPath});
    const indicator = document.getElementById("connIndicator");
    if (data.online) {
      indicator.className = "conn-indicator online";
      document.getElementById("connKernelVersion").textContent = data.kernel_version || "";
      document.getElementById("connOsVersion").textContent = data.os_version || "";
      const mods = (data.loaded_modules || []).slice(0, 8).join(", ");
      document.getElementById("connLoadedModules").textContent =
        data.loaded_modules?.length ? `已加载: ${mods}` : "";
      state.currentSshConn = {host, port, user};
      toast(`连接成功: ${data.kernel_version}`, "success");
    } else {
      indicator.className = "conn-indicator offline";
      document.getElementById("connKernelVersion").textContent = "连接失败";
      document.getElementById("connOsVersion").textContent = data.error || "";
      toast(data.error || "连接失败", "error");
    }
  } catch (e) {
    toast(`测试连接失败: ${e.message}`, "error");
  }
}

function connectDevice(id) {
  const d = state.devices.find((x) => x.id === id);
  if (!d) return;
  document.getElementById("sshHost").value = d.host;
  document.getElementById("sshPort").value = d.port;
  document.getElementById("sshUser").value = d.user;
  document.getElementById("sshKeyPath").value = d.key_path || "";
  switchTab("ssh");
  setTimeout(openSshSession, 150);
}

function openSshSession() {
  const host = document.getElementById("sshHost").value.trim();
  const port = parseInt(document.getElementById("sshPort").value) || 22;
  const user = document.getElementById("sshUser").value.trim() || "nvidia";
  const password = document.getElementById("sshPassword").value;
  const keyPath = document.getElementById("sshKeyPath").value.trim();

  if (!host) { toast("请输入主机地址", "error"); return; }

  state.currentSshConn = {host, port, user};

  document.getElementById("terminalPlaceholder").style.display = "none";
  const xtermEl = document.getElementById("xtermContainer");
  xtermEl.style.display = "block";

  if (!state.term) initXTerm();
  state.term.clear();
  state.term.write("\x1b[1;36m[Connecting to " + user + "@" + host + ":" + port + "...]\x1b[0m\r\n");

  if (state.ws) state.ws.close();

  const wsUrl = `ws://${location.host}/ws/terminal`;
  const ws = new WebSocket(wsUrl);
  state.ws = ws;

  ws.onopen = () => {
    ws.send(JSON.stringify({
      type: "connect", host, port, user, password,
      key_path: keyPath,
      cols: state.term.cols, rows: state.term.rows,
    }));
  };

  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.type === "output") state.term.write(msg.data);
    else if (msg.type === "error") state.term.write("\x1b[31m" + msg.data + "\x1b[0m");
  };

  ws.onclose = () => state.term.write("\r\n\x1b[33m[Disconnected]\x1b[0m\r\n");
  ws.onerror = () => state.term.write("\x1b[31m[WebSocket error]\x1b[0m\r\n");

  state.term.onData((data) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type: "input", data}));
  });

  // Resize -> WS
  const sendResize = () => {
    if (ws.readyState === WebSocket.OPEN && state.term) {
      ws.send(JSON.stringify({type: "resize", cols: state.term.cols, rows: state.term.rows}));
    }
  };
  if (!state._resizeHandlerAttached) {
    state._resizeHandlerAttached = true;
    const ro = new ResizeObserver(() => {
      if (state._fitAddon) state._fitAddon.fit();
      sendResize();
    });
    ro.observe(xtermEl);
  }

  // fallback resize on term resize event
  state.term.onResize(sendResize);
}

function initXTerm() {
  const term = new Terminal({
    cursorBlink: true,
    cursorStyle: "block",
    fontFamily: "'JetBrains Mono', 'Consolas', monospace",
    fontSize: 13,
    theme: {
      background: "#0a0a0f",
      foreground: "#e0e0e8",
      cursor: "#00d4ff",
      cursorAccent: "#0a0a0f",
      selectionBackground: "rgba(0,212,255,0.2)",
      black: "#1a1a2e", red: "#f87171", green: "#34d399", yellow: "#fbbf24",
      blue: "#60a5fa", magenta: "#a78bfa", cyan: "#00d4ff", white: "#e0e0e8",
      brightBlack: "#555570", brightRed: "#fca5a5", brightGreen: "#6ee7b7",
      brightYellow: "#fcd34d", brightBlue: "#93c5fd", brightMagenta: "#c4b5fd",
      brightCyan: "#67e8f9", brightWhite: "#f8f8ff",
    },
    scrollback: 5000,
    allowTransparency: true,
  });

  const fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  term.loadAddon(new WebLinksAddon.WebLinksAddon());

  term.open(document.getElementById("xtermContainer"));
  fitAddon.fit();

  state.term = term;
  state._fitAddon = fitAddon;
}

function disconnectSsh() {
  if (state.ws) {
    try { state.ws.send(JSON.stringify({type: "disconnect"})); } catch (e) {}
    state.ws.close();
    state.ws = null;
  }
  if (state.term) state.term.write("\r\n\x1b[33m[Disconnected]\x1b[0m\r\n");
}

// ─── Modals ───────────────────────────────────────────────────────────────
function closeModal(id) {
  document.getElementById(id).style.display = "none";
}

document.querySelectorAll(".modal-overlay").forEach((overlay) => {
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) overlay.style.display = "none";
  });
});

// ─── Toasts ───────────────────────────────────────────────────────────────
function toast(message, type = "info") {
  const container = document.getElementById("toastContainer");
  const icons = {success: "✓", error: "✗", info: "ℹ"};
  const toastEl = document.createElement("div");
  toastEl.className = `toast ${type}`;
  toastEl.innerHTML = `<span class="toast-icon">${icons[type] || icons.info}</span><span>${message}</span>`;
  container.appendChild(toastEl);
  setTimeout(() => {
    toastEl.style.animation = "toastOut 0.25s ease forwards";
    setTimeout(() => toastEl.remove(), 300);
  }, 3500);
}

// ═══════════════════════════════════════════════════════════════════════════


// ============================================================================
// Firmware Sync
// ============================================================================
function setupFirmwareSync() {
  loadFirmwareConfig();
  loadFirmwarePending();
  loadFirmwareStatus();
  loadFirmwareRemote();
}

async function loadFirmwareRemote() {
  const statusEl = document.getElementById("fwConfigStatus");
  if (!statusEl) return;
  statusEl.textContent = "检测 OneDrive 远程配置...";
  statusEl.style.color = "";
  try {
    const res = await apiGet("/api/firmware/remote");
    if (res.ok) {
      statusEl.textContent = "OneDrive 远程已就绪: " + res.remote;
      statusEl.style.color = "var(--success)";
    } else {
      statusEl.textContent = "OneDrive 未配置: " + res.error;
      statusEl.style.color = "var(--error)";
    }
  } catch (e) {
    statusEl.textContent = "OneDrive 状态检测失败: " + e.message;
    statusEl.style.color = "var(--error)";
  }
}

async function loadFirmwareConfig() {
  try {
    const res = await apiGet("/api/firmware/config");
    const cfg = res.config || {};
    document.getElementById("fwNasHost").value = cfg.nas_host || "";
    document.getElementById("fwNasShare").value = cfg.nas_share || "";
    document.getElementById("fwNasUser").value = cfg.nas_user || "";
    document.getElementById("fwNasPass").value = cfg.nas_pass ? "******" : "";
    document.getElementById("fwNasSubdir").value = cfg.nas_subdir || "";
    document.getElementById("fwOnedriveRemote").value = cfg.onedrive_remote || "";
    document.getElementById("fwOnedrivePath").value = cfg.onedrive_path || "";
    document.getElementById("fwPatterns").value = (cfg.firmware_patterns || []).join(",");
  } catch (e) {
    showToast("加载固件配置失败: " + e.message, "error");
  }
}

function getFirmwareConfigBody() {
  return {
    nas_host: document.getElementById("fwNasHost").value,
    nas_share: document.getElementById("fwNasShare").value,
    nas_user: document.getElementById("fwNasUser").value,
    nas_pass: document.getElementById("fwNasPass").value,
    nas_subdir: document.getElementById("fwNasSubdir").value,
    onedrive_remote: document.getElementById("fwOnedriveRemote").value,
    onedrive_path: document.getElementById("fwOnedrivePath").value,
    firmware_patterns: document.getElementById("fwPatterns").value,
  };
}

async function saveFirmwareConfig() {
  try {
    const body = getFirmwareConfigBody();
    await apiPost("/api/firmware/config", body);
    showToast("配置已保存", "ok");
    loadFirmwareConfig();
  } catch (e) {
    showToast("保存配置失败: " + e.message, "error");
  }
}

async function testNasConnection() {
  const statusEl = document.getElementById("fwConfigStatus");
  statusEl.textContent = "测试中...";
  try {
    const res = await apiGet("/api/firmware/test");
    if (res.ok) {
      statusEl.textContent = "连接成功，共 " + res.count + " 个固件文件";
      statusEl.style.color = "var(--success)";
    } else {
      statusEl.textContent = "连接失败: " + res.error;
      statusEl.style.color = "var(--error)";
    }
  } catch (e) {
    statusEl.textContent = "测试异常: " + e.message;
    statusEl.style.color = "var(--error)";
  }
}

async function scanFirmware() {
  try {
    const res = await apiPost("/api/firmware/scan", {});
    showToast("扫描完成，新增 " + res.new + " 个待上传", "ok");
    renderFirmwarePending(res.pending || []);
    loadFirmwareStatus();
  } catch (e) {
    showToast("扫描失败: " + e.message, "error");
  }
}

async function loadFirmwarePending() {
  try {
    const res = await apiGet("/api/firmware/pending");
    renderFirmwarePending(res.pending || []);
  } catch (e) {
    showToast("加载待上传列表失败: " + e.message, "error");
  }
}

async function loadFirmwareStatus() {
  try {
    const res = await apiGet("/api/firmware/status");
    renderFirmwareStatus(res.uploaded || []);
  } catch (e) {
    showToast("加载已上传记录失败: " + e.message, "error");
  }
}

function renderFirmwarePending(items) {
  const el = document.getElementById("fwPendingList");
  if (!items.length) {
    el.innerHTML = '<div class="empty-state">暂无待上传固件</div>';
    return;
  }
  el.innerHTML = items.map(function(it) {
    return '<div class="job-item">' +
      '<div><strong>' + escapeHtml(it.name) + '</strong></div>' +
      '<div>' + formatBytes(it.size) + ' | mtime: ' + new Date(it.mtime * 1000).toLocaleString() + '</div>' +
      '<button class="btn btn-sm btn-primary" onclick="uploadFirmwareFile(' + JSON.stringify(it.path).replace(/"/g, '&quot;') + ')">上传</button>' +
      '</div>';
  }).join("");
}

function renderFirmwareStatus(items) {
  const el = document.getElementById("fwStatusList");
  if (!items.length) {
    el.innerHTML = '<div class="empty-state">暂无已上传记录</div>';
    return;
  }
  el.innerHTML = items.map(function(it) {
    return '<div class="job-item">' +
      '<div><strong>' + escapeHtml(it.name) + '</strong></div>' +
      '<div>' + formatBytes(it.size) + ' | 上传时间: ' + new Date(it.uploaded_at).toLocaleString() + '</div>' +
      '</div>';
  }).join("");
}

async function uploadFirmwareFile(path) {
  if (!confirm("确认上传 " + path + "?")) return;
  const logCard = document.getElementById("fwLogCard");
  const logEl = document.getElementById("fwLog");
  logCard.style.display = "block";
  logEl.textContent = "开始上传 " + path + "...\\n";
  try {
    const res = await apiPost("/api/firmware/upload", {key: path});
    const job_id = res.job_id;
    const es = new EventSource("/api/firmware/upload/stream/" + job_id);
    es.addEventListener("log", function(e) {
      const msg = JSON.parse(e.data);
      if (msg.line) logEl.textContent += msg.line + "\\n";
    });
    es.addEventListener("done", function(e) {
      es.close();
      const msg = JSON.parse(e.data);
      showToast(msg.message || "上传结束", msg.status === "ok" ? "ok" : "error");
      loadFirmwarePending();
      loadFirmwareStatus();
    });
  } catch (e) {
    logEl.textContent += "❌ " + e.message + "\\n";
    showToast("上传失败: " + e.message, "error");
  }
}

async function uploadAllFirmware() {
  const logCard = document.getElementById("fwLogCard");
  const logEl = document.getElementById("fwLog");
  logCard.style.display = "block";
  logEl.textContent = "开始上传所有待传固件...\n";
  try {
    const res = await apiPost("/api/firmware/upload-pending", {});
    const job_id = res.job_id;
    const es = new EventSource("/api/firmware/upload/stream/" + job_id);
    es.addEventListener("log", function(e) {
      const msg = JSON.parse(e.data);
      if (msg.line) logEl.textContent += msg.line + "\\n";
    });
    es.addEventListener("done", function(e) {
      es.close();
      const msg = JSON.parse(e.data);
      showToast(msg.message || "批量上传结束", msg.status === "ok" ? "ok" : "error");
      loadFirmwarePending();
      loadFirmwareStatus();
    });
  } catch (e) {
    logEl.textContent += "❌ " + e.message + "\\n";
    showToast("上传失败: " + e.message, "error");
  }
}


// ════════════════════════════════════════════════════════════════════════════════════
// Thor Firmware Build
// ════════════════════════════════════════════════════════════════════════════════════

let thorTerminal = null;

async function thorInit() {
  thorCheckRecovery();
  thorRefreshStatus();
  if (!thorTerminal) {
    thorTerminal = new Terminal({
      rows: 20,
      theme: { background: "#0d1117", foreground: "#c9d1d9" },
      fontSize: 13,
      fontFamily: "Monaco, Consolas, monospace",
    });
    thorTerminal.fitAddon = new FitAddon.FitAddon();
    thorTerminal.loadAddon(new WebLinksAddon.WebLinksAddon());
    thorTerminal.open(document.getElementById("thorTerminal"));
    thorTerminal.fitAddon.fit();
  }
}

async function thorCheckRecovery() {
  const indicator = document.getElementById("thorRecoveryIndicator");
  const text = document.getElementById("thorRecoveryText");
  indicator.className = "indicator checking";
  text.textContent = "检查中...";
  try {
    const res = await apiGet("/api/firmware/thor/check-recovery");
    if (res.connected) {
      indicator.className = "indicator online";
      text.textContent = res.description || "Thor Recovery 已连接";
    } else {
      indicator.className = "indicator offline";
      text.textContent = "Thor 未进入 Recovery 模式";
    }
  } catch (e) {
    indicator.className = "indicator offline";
    text.textContent = "检查失败: " + e.message;
  }
}

async function thorRefreshStatus() {
  try {
    const res = await apiGet("/api/firmware/thor/status");
    const ready = res.l4t_ready;
    document.querySelectorAll("#thorWorkflowSteps .workflow-step button").forEach(function(btn) {
      btn.disabled = !ready;
    });
  } catch (e) {
    console.error("Thor status refresh failed:", e);
  }
}

async function thorRunStage(stage) {
  if (!thorTerminal) {
    thorTerminal = new Terminal({
      rows: 20,
      theme: { background: "#0d1117", foreground: "#c9d1d9" },
      fontSize: 13,
      fontFamily: "Monaco, Consolas, monospace",
    });
    thorTerminal.open(document.getElementById("thorTerminal"));
  }
  thorTerminal.clear();
  thorTerminal.writeln("[Thor] 开始执行: " + stage);

  if (stage === "flash" || stage === "all") {
    await thorCheckRecovery();
    const res = await apiGet("/api/firmware/thor/check-recovery");
    if (!res.connected) {
      thorTerminal.writeln("\\x1b[31m[错误] Thor 未进入 Recovery 模式！\\x1b[0m");
      thorTerminal.writeln("请确保设备已连接并进入 Recovery 模式:");
      thorTerminal.writeln("  1. 关闭设备电源");
      thorTerminal.writeln("  2. 连接 USB Type-C 到主机");
      thorTerminal.writeln("  3. 按住 Force Recovery 键");
      thorTerminal.writeln("  4. 按 Power 键开机");
      thorTerminal.writeln("  5. 运行 'lsusb' 检查 0955:7045");
      return;
    }
  }

  const req = {
    bsp_version: document.getElementById("thorBspVersion").value,
    stage: stage,
    default_user: document.getElementById("thorDefaultUser").value,
    default_password: document.getElementById("thorDefaultPass").value,
    default_hostname: document.getElementById("thorHostname").value,
    board_id: document.getElementById("thorBoardId").value,
    board_sku: document.getElementById("thorBoardSku").value,
    fab: document.getElementById("thorFab").value,
    board_rev: document.getElementById("thorBoardRev").value,
  };

  try {
    const res = await apiPost("/api/firmware/thor/build", req);
    const es = new EventSource("/api/firmware/thor/build/stream/" + res.job_id);
    es.addEventListener("progress", function(e) {
      const msg = JSON.parse(e.data);
      thorTerminal.writeln("[" + (msg.stage || "progress") + "] " + msg.message);
    });
    es.addEventListener("error", function(e) {
      const msg = JSON.parse(e.data);
      thorTerminal.writeln("\\x1b[31m[错误] " + msg.message + "\\x1b[0m");
    });
    es.addEventListener("done", function(e) {
      es.close();
      const msg = JSON.parse(e.data);
      if (msg.status === "ok") {
        thorTerminal.writeln("\\x1b[32m✓ 完成: " + msg.message + "\\x1b[0m");
        showToast(msg.message, "ok");
      } else {
        thorTerminal.writeln("\\x1b[31m✗ 失败: " + msg.message + "\\x1b[0m");
        showToast(msg.message, "error");
      }
    });
  } catch (e) {
    thorTerminal.writeln("\\x1b[31m[错误] " + e.message + "\\x1b[0m");
    showToast("Thor 编译请求失败: " + e.message, "error");
  }
}

async function thorCleanup() {
  if (!confirm("确定清理 Thor 构建产物？")) return;
  showToast("清理请求已发送", "ok");
}


// ════════════════════════════════════════════════════════════════════════════════════
// DIY Hybrid BSP
// ════════════════════════════════════════════════════════════════════════════════════

let hybridTerminal = null;

async function hybridInit() {
  hybridCheckRecovery();
  hybridRefreshStatus();
  if (!hybridTerminal) {
    hybridTerminal = new Terminal({
      rows: 20,
      theme: { background: "#0d1117", foreground: "#c9d1d9" },
      fontSize: 13,
      fontFamily: "Monaco, Consolas, monospace",
    });
    hybridTerminal.fitAddon = new FitAddon.FitAddon();
    hybridTerminal.loadAddon(new WebLinksAddon.WebLinksAddon());
    hybridTerminal.open(document.getElementById("hybridTerminal"));
    hybridTerminal.fitAddon.fit();
  }
}

async function hybridCheckRecovery() {
  const indicator = document.getElementById("hybridRecoveryIndicator");
  const text = document.getElementById("hybridRecoveryText");
  indicator.className = "indicator checking";
  text.textContent = "检查中...";
  try {
    const res = await apiGet("/api/firmware/hybrid/check-recovery");
    if (res.connected) {
      indicator.className = "indicator online";
      text.textContent = res.description || "Orin Recovery 已连接";
    } else {
      indicator.className = "indicator offline";
      text.textContent = "Orin 未进入 Recovery 模式";
    }
  } catch (e) {
    indicator.className = "indicator offline";
    text.textContent = "检查失败: " + e.message;
  }
}

async function hybridRefreshStatus() {
  try {
    const res = await apiGet("/api/firmware/hybrid/status");
    const items = [
      { id: "hybridBackupStatus", ready: res.backup_exists },
      { id: "hybridAppStatus", ready: res.app_only_exists },
      { id: "hybridQspiStatus", ready: res.qspi_generated },
      { id: "hybridAssembleStatus", ready: res.mfi_exists },
      { id: "hybridFlashStatus", ready: false },
    ];
    items.forEach(function(item) {
      const el = document.getElementById(item.id);
      if (el) {
        el.textContent = item.ready ? "✓" : "-";
        el.className = item.ready ? "status-value ready" : "status-value";
      }
    });
  } catch (e) {
    console.error("Hybrid status refresh failed:", e);
  }
}

function hybridOnTargetChange() {
  var target = document.getElementById("hybridTargetBoard").value;
  document.getElementById("hybridModuleSku").value = "0005";
  document.getElementById("hybridFab").value = "300";
  document.getElementById("hybridBoardRev").value = "V.2";
}

function hybridEnsureTerminal() {
  if (!hybridTerminal) {
    hybridTerminal = new Terminal({
      rows: 20,
      theme: { background: "#0d1117", foreground: "#c9d1d9" },
      fontSize: 13,
      fontFamily: "Monaco, Consolas, monospace",
    });
    hybridTerminal.open(document.getElementById("hybridTerminal"));
  }
}

function hybridLog(msg) {
  hybridEnsureTerminal();
  hybridTerminal.writeln(msg);
}

async function hybridRunApi(endpoint, request) {
  hybridLog("[Hybrid] 正在请求 " + endpoint + "...");
  try {
    const res = await apiPost(endpoint, request);
    const es = new EventSource("/api/firmware/hybrid/stream/" + res.job_id);
    es.addEventListener("progress", function(e) {
      const msg = JSON.parse(e.data);
      hybridLog("  " + msg.message);
    });
    es.addEventListener("error", function(e) {
      const msg = JSON.parse(e.data);
      hybridLog("\\x1b[31m[错误] " + msg.message + "\\x1b[0m");
    });
    es.addEventListener("done", function(e) {
      es.close();
      const msg = JSON.parse(e.data);
      if (msg.status === "ok") {
        hybridLog("\\x1b[32m✓ 成功: " + msg.message + "\\x1b[0m");
        showToast(msg.message, "ok");
      } else {
        hybridLog("\\x1b[31m✗ 失败: " + msg.message + "\\x1b[0m");
        showToast(msg.message, "error");
      }
      hybridRefreshStatus();
    });
  } catch (e) {
    hybridLog("\\x1b[31m[错误] " + e.message + "\\x1b[0m");
    showToast("请求失败: " + e.message, "error");
  }
}

async function hybridBackup() {
  hybridEnsureTerminal();
  hybridTerminal.clear();
  hybridLog("=== Hybrid BSP: 备份 DevKit ===");
  hybridLog("请确保 DevKit 已进入 Recovery 模式 (lsusb 显示 0955:7523)");
  hybridLog("");
  await hybridCheckRecovery();
  const res = await apiGet("/api/firmware/hybrid/check-recovery");
  if (!res.connected) {
    hybridLog("\\x1b[31m[错误] DevKit 未进入 Recovery 模式！\\x1b[0m");
    hybridLog("请先让 DevKit 进入 Recovery 模式后再试。");
    return;
  }
  const req = {
    bsp_version: document.getElementById("hybridBspVersion").value,
    source_board: document.getElementById("hybridSourceBoard").value,
  };
  await hybridRunApi("/api/firmware/hybrid/backup", req);
}

async function hybridPrepareApp() {
  hybridEnsureTerminal();
  hybridLog("=== Hybrid BSP: 准备 APP-only ===");
  const req = {
    bsp_version: document.getElementById("hybridBspVersion").value,
    target_board: document.getElementById("hybridTargetBoard").value,
  };
  await hybridRunApi("/api/firmware/hybrid/prepare-app", req);
}

async function hybridGenerateQspi() {
  hybridEnsureTerminal();
  hybridLog("=== Hybrid BSP: 生成目标板 QSPI ===");
  hybridLog("请确保目标板已进入 Recovery 模式");
  hybridLog("");
  await hybridCheckRecovery();
  const res = await apiGet("/api/firmware/hybrid/check-recovery");
  if (!res.connected) {
    hybridLog("\\x1b[31m[错误] 目标板未进入 Recovery 模式！\\x1b[0m");
    return;
  }
  const req = {
    bsp_version: document.getElementById("hybridBspVersion").value,
    target_board: document.getElementById("hybridTargetBoard").value,
    module_sku: document.getElementById("hybridModuleSku").value,
    fab: document.getElementById("hybridFab").value,
    board_rev: document.getElementById("hybridBoardRev").value,
  };
  await hybridRunApi("/api/firmware/hybrid/generate-qspi", req);
}

async function hybridAssemble() {
  hybridEnsureTerminal();
  hybridLog("=== Hybrid BSP: 组装 mfi ===");
  const req = {
    bsp_version: document.getElementById("hybridBspVersion").value,
    target_board: document.getElementById("hybridTargetBoard").value,
  };
  await hybridRunApi("/api/firmware/hybrid/assemble", req);
}

async function hybridFlash() {
  hybridEnsureTerminal();
  hybridLog("=== Hybrid BSP: 烧录目标板 ===");
  hybridLog("请确保目标板已进入 Recovery 模式");
  hybridLog("");
  await hybridCheckRecovery();
  const res = await apiGet("/api/firmware/hybrid/check-recovery");
  if (!res.connected) {
    hybridLog("\\x1b[31m[错误] 目标板未进入 Recovery 模式！\\x1b[0m");
    return;
  }
  const req = {
    bsp_version: document.getElementById("hybridBspVersion").value,
    target_board: document.getElementById("hybridTargetBoard").value,
  };
  await hybridRunApi("/api/firmware/hybrid/flash", req);
}


function escapeHtml(str) {
  if (!str) return "";
  return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function formatBytes(bytes) {
  if (!bytes) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
}
