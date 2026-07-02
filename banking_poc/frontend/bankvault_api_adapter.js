(function () {
  const configuredCredentials = window.BANKVAULT_CREDENTIALS || { username: "alex", password: "demo" };
  const state = {
    token: "",
    credentials: loadCredentials(),
    summary: null,
    recipients: [],
    users: [],
    activeWorkflowStep: 1,
    workflowStatus: "App UI loaded from frontend nginx.",
    flowEvents: [{
      time: "load",
      step: 1,
      action: "Open mobile banking app",
      message: "Browser loaded frontend HTML, config, and live adapter.",
    }],
  };

  const workflowRows = [
    {
      step: 1,
      action: "Open mobile banking app",
      first: "Frontend Web / Mobile App :8080",
      backend: "nginx serves banking_app.html and bankvault_api_adapter.js",
      data: "No banking data created. App loads UI and API config.",
      nodes: ["Browser", "Frontend nginx :8080", "banking_app.html", "bankvault_api_adapter.js"],
    },
    {
      step: 2,
      action: "Register new user",
      first: "API Gateway :8100",
      backend: "Core Banking :8102 -> Database Service :8106",
      data: "Creates customer profile, username/password record, checking account, savings account, opening deposit transaction.",
      nodes: ["Mobile App", "API Gateway :8100", "Core Banking :8102", "Database Service :8106", "Bank DB"],
    },
    {
      step: 3,
      action: "Log in",
      first: "API Gateway :8100",
      backend: "Auth Service :8101 -> Database Service :8106",
      data: "Reads user credentials. Creates signed login token returned to mobile app.",
      nodes: ["Mobile App", "API Gateway :8100", "Auth Service :8101", "Database Service :8106", "Signed Token"],
    },
    {
      step: 4,
      action: "View account dashboard",
      first: "API Gateway :8100",
      backend: "Core Banking :8102 -> Database Service :8106",
      data: "Reads customer profile, accounts, balances, recent transactions.",
      nodes: ["Mobile App", "API Gateway :8100", "Core Banking :8102", "Database Service :8106", "Dashboard UI"],
    },
    {
      step: 5,
      action: "Search/validate recipient username",
      first: "API Gateway :8100",
      backend: "Core Banking :8102 -> Database Service :8106",
      data: "Reads recipient customer and default checking account. No money moved yet.",
      nodes: ["Mobile App", "API Gateway :8100", "Core Banking :8102", "Database Service :8106", "Recipient Account"],
    },
    {
      step: 6,
      action: "Submit money transfer",
      first: "API Gateway :8100",
      backend: "Ledger / Transfer Service :8103 -> Database Service :8106",
      data: "Creates transfer transaction. Debits source account balance. Credits destination account balance.",
      nodes: ["Mobile App", "API Gateway :8100", "Ledger Service :8103", "Database Service :8106", "Debit + Credit"],
    },
    {
      step: 7,
      action: "Record compliance event",
      first: "Ledger / Transfer Service :8103",
      backend: "Audit / Compliance Log :8104 -> Database Service :8106",
      data: "Creates audit event for posted transfer.",
      nodes: ["Ledger Service :8103", "Audit Service :8104", "Database Service :8106", "Audit Record"],
    },
    {
      step: 8,
      action: "Send transfer notification",
      first: "Ledger / Transfer Service :8103",
      backend: "Notification Service :8105 -> Database Service :8106",
      data: "Creates simulated mobile/SMS/email notification record.",
      nodes: ["Ledger Service :8103", "Notification Service :8105", "Database Service :8106", "Notification Record"],
    },
    {
      step: 9,
      action: "Refresh account dashboard",
      first: "API Gateway :8100",
      backend: "Core Banking :8102 -> Database Service :8106",
      data: "Reads updated balances and transaction history after transfer.",
      nodes: ["Mobile App", "API Gateway :8100", "Core Banking :8102", "Database Service :8106", "Updated Dashboard"],
    },
    {
      step: 10,
      action: "Readiness/session-style checks",
      first: "API Gateway :8100",
      backend: "Cache Service :8107 -> Redis",
      data: "Reads/writes lightweight cache health/session-style POC checks.",
      nodes: ["Mobile App", "API Gateway :8100", "Cache Service :8107", "Redis"],
    },
  ];

  const utilityBills = {
    Rent: { icon: "🏠", amount_cents: 120000 },
    Electricity: { icon: "⚡", amount_cents: 8740 },
    Mobile: { icon: "📱", amount_cents: 5500 },
    Internet: { icon: "🌐", amount_cents: 6999 },
    Car: { icon: "🚗", amount_cents: 42500 },
  };

  function loadCredentials() {
    try {
      const saved = JSON.parse(localStorage.getItem("bankvault_credentials") || "null");
      if (saved && saved.username && saved.password) return saved;
    } catch (_) {}
    return configuredCredentials;
  }

  function saveCredentials(credentials) {
    state.credentials = credentials;
    localStorage.setItem("bankvault_credentials", JSON.stringify(credentials));
    sessionStorage.removeItem("bankvault_token");
    state.token = "";
  }

  function cents(value) {
    return "$" + (Number(value || 0) / 100).toLocaleString("en-US", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
  }

  function centsFromDollars(value) {
    const parsed = Number.parseFloat(String(value || "0").replace(/[$,]/g, ""));
    if (!Number.isFinite(parsed) || parsed <= 0) return 0;
    return Math.round(parsed * 100);
  }

  function escapeHtml(value) {
    return String(value || "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    }[c]));
  }

  async function api(path, options) {
    const response = await fetch(path, Object.assign({ cache: "no-store" }, options || {}));
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const message = payload.error || payload.detail || path + " returned " + response.status;
      throw new Error(message);
    }
    return payload;
  }

  async function login(force) {
    if (!force) {
      const token = sessionStorage.getItem("bankvault_token");
      if (token) {
        state.token = token;
        return token;
      }
    }
    const payload = await api("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(state.credentials),
    });
    sessionStorage.setItem("bankvault_token", payload.access_token);
    state.token = payload.access_token;
    return payload.access_token;
  }

  function injectStyles() {
    if (document.getElementById("bankvault-live-style")) return;
    const style = document.createElement("style");
    style.id = "bankvault-live-style";
    style.textContent = `
      .bankvault-live-panel {
        margin: 18px 0;
        padding: 14px;
        border-radius: 22px;
        background: rgba(255, 255, 255, 0.96);
        box-shadow: 0 18px 38px rgba(31, 38, 135, 0.18);
        border: 1px solid rgba(102, 126, 234, 0.18);
        color: #172033;
      }
      .bankvault-live-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 10px;
        margin-bottom: 12px;
      }
      .bankvault-live-head h3 {
        margin: 0;
        font-size: 15px;
        color: #172033;
      }
      .bankvault-live-user {
        font-size: 11px;
        color: #64748b;
        font-weight: 700;
      }
      .bankvault-tabs {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        gap: 6px;
        margin-bottom: 12px;
      }
      .bankvault-tab,
      .bankvault-action {
        border: 0;
        border-radius: 12px;
        padding: 9px 10px;
        background: #edf2ff;
        color: #3451b2;
        font-size: 12px;
        font-weight: 800;
        cursor: pointer;
      }
      .bankvault-tab.active,
      .bankvault-action.primary {
        background: linear-gradient(135deg, #667eea, #764ba2);
        color: white;
      }
      .bankvault-form {
        display: none;
        gap: 8px;
      }
      .bankvault-transfer-card {
        display: none;
      }
      .bankvault-transfer-card.active,
      .bankvault-form.active,
      .bankvault-dev-view.active {
        display: grid;
      }
      .bankvault-dev-view {
        display: none;
        gap: 10px;
      }
      .bankvault-grid-2 {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 8px;
      }
      .bankvault-field {
        display: grid;
        gap: 4px;
      }
      .bankvault-field label {
        color: #64748b;
        font-size: 10px;
        font-weight: 800;
        text-transform: uppercase;
      }
      .bankvault-field input,
      .bankvault-field select {
        width: 100%;
        border: 1px solid #d8e2f0;
        border-radius: 12px;
        padding: 10px 11px;
        background: #f8fafc;
        color: #172033;
        font-size: 13px;
        outline: none;
      }
      .bankvault-status {
        min-height: 18px;
        margin-top: 8px;
        font-size: 11px;
        color: #64748b;
        font-weight: 700;
      }
      .bankvault-status.ok { color: #059669; }
      .bankvault-status.err { color: #dc2626; }
      .bankvault-close {
        border: 0;
        border-radius: 999px;
        background: #fee2e2;
        color: #991b1b;
        padding: 6px 9px;
        font-size: 11px;
        font-weight: 900;
        cursor: pointer;
      }
      .bankvault-shortcuts {
        display: flex;
        gap: 6px;
        flex-wrap: wrap;
        margin-bottom: 10px;
      }
      .bankvault-shortcuts button {
        border: 1px solid #d8e2f0;
        border-radius: 999px;
        background: white;
        color: #3451b2;
        padding: 6px 9px;
        font-size: 11px;
        font-weight: 800;
        cursor: pointer;
      }
      .bankvault-flow-card {
        border: 1px solid #d8e2f0;
        border-radius: 14px;
        background: #f8fafc;
        overflow: hidden;
      }
      .bankvault-feature-view {
        display: none;
        margin: 18px 0;
        padding: 14px;
        border-radius: 22px;
        background: rgba(255, 255, 255, 0.96);
        box-shadow: 0 18px 38px rgba(31, 38, 135, 0.18);
        border: 1px solid rgba(102, 126, 234, 0.18);
        color: #172033;
      }
      .bankvault-feature-view.active {
        display: grid;
        gap: 12px;
      }
      .bankvault-feature-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 10px;
      }
      .bankvault-feature-head h3 {
        margin: 0;
        font-size: 16px;
      }
      .bankvault-feature-grid {
        display: grid;
        gap: 8px;
      }
      .bankvault-mini-card {
        border: 1px solid #d8e2f0;
        border-radius: 14px;
        padding: 10px;
        background: #f8fafc;
      }
      .bankvault-card-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 10px;
        font-size: 12px;
        font-weight: 800;
      }
      .bankvault-progress {
        height: 8px;
        border-radius: 999px;
        background: #e2e8f0;
        margin-top: 7px;
        overflow: hidden;
      }
      .bankvault-progress span {
        display: block;
        height: 100%;
        border-radius: inherit;
        background: linear-gradient(135deg, #667eea, #764ba2);
      }
      .bankvault-chart {
        display: grid;
        grid-template-columns: repeat(5, 1fr);
        align-items: end;
        gap: 7px;
        height: 94px;
        padding: 8px;
        border-radius: 14px;
        background: #f1f5f9;
      }
      .bankvault-bar {
        border-radius: 8px 8px 3px 3px;
        background: linear-gradient(180deg, #00ff88, #0891b2);
        min-height: 20px;
      }
      .bankvault-utility-grid {
        display: grid;
        grid-template-columns: repeat(2, 1fr);
        gap: 8px;
      }
      .transaction-item .tx-details {
        min-width: 0;
      }
      .transaction-item .tx-name {
        overflow-wrap: anywhere;
        line-height: 1.25;
      }
      .transaction-item .tx-date {
        margin-top: 3px;
      }
      .bankvault-flow-head {
        display: flex;
        justify-content: space-between;
        align-items: center;
        gap: 10px;
        padding: 10px 12px;
        background: #172033;
        color: #d1fae5;
        font-size: 11px;
        font-weight: 900;
        text-transform: uppercase;
      }
      .bankvault-flow-pill {
        border-radius: 999px;
        padding: 5px 8px;
        background: rgba(0, 255, 136, 0.14);
        color: #00ff88;
        white-space: nowrap;
      }
      .bankvault-flow-scroll {
        overflow-x: auto;
      }
      .bankvault-route-panel {
        display: grid;
        gap: 8px;
        padding: 10px;
        background: #08111f;
        border-bottom: 1px solid #1f3b57;
      }
      .bankvault-route-title {
        color: #38bdf8;
        font-size: 10px;
        font-weight: 900;
        text-transform: uppercase;
      }
      .bankvault-route-line {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 6px;
      }
      .bankvault-route-node {
        display: inline-flex;
        align-items: center;
        min-height: 26px;
        border-radius: 999px;
        border: 1px solid rgba(56, 189, 248, 0.45);
        background: rgba(14, 165, 233, 0.12);
        color: #e0f2fe;
        padding: 5px 8px;
        font-size: 10px;
        font-weight: 900;
      }
      .bankvault-route-arrow {
        color: #00ff88;
        font-weight: 900;
      }
      .bankvault-log {
        display: grid;
        gap: 3px;
        max-height: 96px;
        overflow: auto;
        padding: 9px 10px;
        background: #020617;
        color: #00ff88;
        font-family: "Courier New", monospace;
        font-size: 10px;
        border-bottom: 1px solid #1f3b57;
      }
      .bankvault-log-line {
        white-space: normal;
      }
      .bankvault-log-time {
        color: #38bdf8;
      }
      .bankvault-flow-table {
        width: 100%;
        min-width: 920px;
        border-collapse: collapse;
        font-size: 11px;
      }
      .bankvault-flow-table th,
      .bankvault-flow-table td {
        border-bottom: 1px solid #d8e2f0;
        padding: 9px 10px;
        text-align: left;
        vertical-align: top;
      }
      .bankvault-flow-table th {
        background: #eef4ff;
        color: #172033;
        font-size: 10px;
        text-transform: uppercase;
      }
      .bankvault-flow-table tr.active-step {
        background: #dcfce7;
        box-shadow: inset 4px 0 0 #16a34a;
      }
      .bankvault-flow-table tr.recent-step {
        background: #eff6ff;
      }
      .bankvault-flow-step {
        display: inline-flex;
        width: 22px;
        height: 22px;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        background: #e0f2fe;
        color: #0369a1;
        font-weight: 900;
      }
      .bankvault-flow-table tr.active-step .bankvault-flow-step {
        background: #16a34a;
        color: white;
      }
      .bankvault-flow-note {
        color: #64748b;
        font-size: 11px;
        font-weight: 700;
      }
      .bankvault-external-dev {
        position: fixed;
        left: 30px;
        top: 92px;
        width: min(665px, calc(50vw - 70px));
        height: calc(100vh - 130px);
        z-index: 20;
      }
      .bankvault-external-dev .bankvault-flow-card {
        height: calc(100% - 26px);
        background: rgba(248, 250, 252, 0.98);
        border-color: rgba(216, 226, 240, 0.65);
        box-shadow: 0 24px 60px rgba(0, 0, 0, 0.25);
      }
      .bankvault-external-dev .bankvault-flow-scroll {
        height: calc(100% - 198px);
        overflow: auto;
      }
      .bankvault-external-dev .bankvault-flow-table {
        min-width: 0;
        table-layout: fixed;
        font-size: 10px;
      }
      .bankvault-external-dev .bankvault-flow-table th,
      .bankvault-external-dev .bankvault-flow-table td {
        padding: 7px 8px;
        line-height: 1.25;
        word-break: normal;
        overflow-wrap: anywhere;
      }
      .bankvault-external-dev .bankvault-flow-table th:first-child,
      .bankvault-external-dev .bankvault-flow-table td:first-child {
        width: 48px;
      }
      .bankvault-external-dev .bankvault-flow-table th:nth-child(2),
      .bankvault-external-dev .bankvault-flow-table td:nth-child(2) {
        width: 120px;
      }
      .bankvault-external-dev .bankvault-flow-table th:nth-child(3),
      .bankvault-external-dev .bankvault-flow-table td:nth-child(3) {
        width: 135px;
      }
      .bankvault-external-dev .bankvault-flow-table th:nth-child(4),
      .bankvault-external-dev .bankvault-flow-table td:nth-child(4) {
        width: 160px;
      }
      .bankvault-external-dev .bankvault-flow-note {
        color: #dbeafe;
        margin-top: 8px;
      }
      @media (max-width: 1180px) {
        .bankvault-external-dev {
          position: static;
          width: auto;
          height: 520px;
          margin: 18px;
        }
      }
      @media (max-width: 520px) {
        .bankvault-tabs {
          grid-template-columns: repeat(3, 1fr);
        }
        .bankvault-grid-2 {
          grid-template-columns: 1fr;
        }
      }
    `;
    document.head.appendChild(style);
  }

  function injectExternalDevView() {
    if (document.getElementById("bankvaultDevView")) return;
    const host = document.querySelector(".phone-frame") || document.body.firstElementChild;
    const dev = document.createElement("div");
    dev.id = "bankvaultDevView";
    dev.className = "bankvault-dev-view active bankvault-external-dev";
    dev.innerHTML = `
      <div class="bankvault-flow-card">
        <div class="bankvault-flow-head">
          <span>Dev View - Live Data Movement</span>
          <span class="bankvault-flow-pill" id="bankvaultFlowStatus">Step 1 active</span>
        </div>
        <div class="bankvault-route-panel">
          <div class="bankvault-route-title">Active Data Route</div>
          <div class="bankvault-route-line" id="bankvaultFlowPath"></div>
        </div>
        <div class="bankvault-log" id="bankvaultFlowLog">
          <div class="bankvault-log-line"><span class="bankvault-log-time">[ready]</span> waiting for mobile app action</div>
        </div>
        <div class="bankvault-flow-scroll">
          <table class="bankvault-flow-table">
            <thead>
              <tr>
                <th>Step</th>
                <th>Mobile App Action</th>
                <th>Main Component Hit First</th>
                <th>Backend Components Used</th>
                <th>Data Created / Read / Updated</th>
              </tr>
            </thead>
            <tbody id="bankvaultFlowRows"></tbody>
          </table>
        </div>
      </div>
      <div class="bankvault-flow-note">Rows highlight as the mobile app calls each component path.</div>
    `;
    if (host && host.parentNode) {
      host.parentNode.insertBefore(dev, host);
    } else {
      document.body.prepend(dev);
    }
  }

  function injectPanel() {
    const existingPanel = document.getElementById("bankvault-live-panel");
    if (existingPanel) {
      ensureTransferCard();
      ensureFeatureView();
      ensureFallbackPickers();
      positionLabPanel();
      wirePanel();
      renderDevView();
      return;
    }
    const quickActions = document.querySelector(".quick-actions");
    if (!quickActions) return;
    const panel = document.createElement("div");
    panel.id = "bankvault-live-panel";
    panel.className = "bankvault-live-panel";
    panel.innerHTML = `
      <div class="bankvault-live-head">
        <h3>PIGGYBANK Login</h3>
        <div class="bankvault-live-user" id="bankvaultCurrentUser">Signed in as ${escapeHtml(state.credentials.username)}</div>
      </div>
      <div class="bankvault-shortcuts">
        <button type="button" data-switch-user="alex" data-switch-pass="demo">Alex</button>
        <button type="button" data-switch-user="alice" data-switch-pass="demo">Alice</button>
        <button type="button" id="bankvaultRefreshBtn">Refresh</button>
      </div>
      <div class="bankvault-tabs">
        <button type="button" class="bankvault-tab active" data-bankvault-tab="login">Login</button>
        <button type="button" class="bankvault-tab" data-bankvault-tab="register">Register</button>
      </div>
      <form class="bankvault-form" id="bankvaultRegisterForm">
        <div class="bankvault-grid-2">
          <div class="bankvault-field">
            <label>Username</label>
            <input id="bankvaultRegUsername" placeholder="new.user">
          </div>
          <div class="bankvault-field">
            <label>Password</label>
            <input id="bankvaultRegPassword" type="password" value="demo">
          </div>
        </div>
        <div class="bankvault-field">
          <label>Full name</label>
          <input id="bankvaultRegName" placeholder="New Customer">
        </div>
        <div class="bankvault-grid-2">
          <div class="bankvault-field">
            <label>Email</label>
            <input id="bankvaultRegEmail" type="email" placeholder="new.customer@example.com">
          </div>
          <div class="bankvault-field">
            <label>Opening deposit</label>
            <input id="bankvaultRegDeposit" value="500.00" inputmode="decimal">
          </div>
        </div>
        <button type="submit" class="bankvault-action primary">Create Account</button>
      </form>
      <form class="bankvault-form active" id="bankvaultLoginForm">
        <div class="bankvault-grid-2">
          <div class="bankvault-field">
            <label>Username</label>
            <input id="bankvaultLoginUsername" value="${escapeHtml(state.credentials.username)}">
          </div>
          <div class="bankvault-field">
            <label>Password</label>
            <input id="bankvaultLoginPassword" type="password" value="${escapeHtml(state.credentials.password)}">
          </div>
        </div>
        <div class="bankvault-field">
          <label>Bank account number</label>
          <input id="bankvaultLoginAccount" value="acct-checking" readonly>
        </div>
        <button type="submit" class="bankvault-action primary">Log In</button>
      </form>
      <div class="bankvault-status" id="bankvaultStatus"></div>
    `;
    quickActions.insertAdjacentElement("afterend", panel);
    ensureTransferCard();
    ensureFeatureView();
    ensureFallbackPickers();
    positionLabPanel();
    wirePanel();
    renderDevView();
  }

  function ensureTransferCard() {
    if (document.getElementById("bankvaultTransferForm")) return;
    const quickActions = document.querySelector(".quick-actions");
    if (!quickActions) return;
    const form = document.createElement("form");
    form.id = "bankvaultTransferForm";
    form.className = "bankvault-live-panel bankvault-transfer-card";
    form.innerHTML = `
      <div class="bankvault-live-head">
        <h3>Send Money</h3>
        <button type="button" class="bankvault-close" data-bank-close-transfer>Close</button>
      </div>
      <div class="bankvault-field">
        <label>From account</label>
        <select id="bankvaultFromAccount"></select>
      </div>
      <div class="bankvault-grid-2">
        <div class="bankvault-field">
          <label>Recipient</label>
          <select id="bankvaultToUsername"></select>
        </div>
        <div class="bankvault-field">
          <label>Amount</label>
          <input id="bankvaultAmount" value="25.00" inputmode="decimal">
        </div>
      </div>
      <div class="bankvault-field">
        <label>Description</label>
        <input id="bankvaultDescription" value="Mobile transfer">
      </div>
      <button type="submit" class="bankvault-action primary">Send Money</button>
    `;
    quickActions.insertAdjacentElement("afterend", form);
  }

  function ensureFeatureView() {
    if (document.getElementById("bankvaultFeatureView")) return;
    const transfer = document.getElementById("bankvaultTransferForm");
    if (!transfer) return;
    const view = document.createElement("div");
    view.id = "bankvaultFeatureView";
    view.className = "bankvault-feature-view";
    transfer.insertAdjacentElement("afterend", view);
  }

  function positionLabPanel() {
    const panel = document.getElementById("bankvault-live-panel");
    const header = document.querySelector(".app-header");
    if (panel && header && panel.previousElementSibling !== header) {
      header.insertAdjacentElement("afterend", panel);
    }
  }

  function setStatus(message, mode) {
    const el = document.getElementById("bankvaultStatus");
    if (!el) return;
    el.textContent = message || "";
    el.className = "bankvault-status" + (mode ? " " + mode : "");
  }

  function selectTab(name) {
    document.querySelectorAll(".bankvault-tab").forEach((tab) => {
      tab.classList.toggle("active", tab.dataset.bankvaultTab === name);
    });
    document.getElementById("bankvaultRegisterForm")?.classList.toggle("active", name === "register");
    document.getElementById("bankvaultLoginForm")?.classList.toggle("active", name === "login");
    if (name === "login" || name === "register") {
      document.getElementById("bankvaultTransferForm")?.classList.remove("active");
    }
  }

  function markWorkflowStep(step, status) {
    state.activeWorkflowStep = step;
    state.workflowStatus = status || workflowRows.find((row) => row.step === step)?.action || "";
    addFlowEvent(step, state.workflowStatus);
    renderDevView();
  }

  function addFlowEvent(step, message) {
    const row = workflowRows.find((item) => item.step === step);
    const now = new Date().toLocaleTimeString();
    state.flowEvents.unshift({
      time: now,
      step,
      action: row ? row.action : "Workflow",
      message,
    });
    state.flowEvents = state.flowEvents.slice(0, 16);
  }

  function renderDevView() {
    const rows = document.getElementById("bankvaultFlowRows");
    if (!rows) return;
    const active = workflowRows.find((row) => row.step === state.activeWorkflowStep) || workflowRows[0];
    const path = document.getElementById("bankvaultFlowPath");
    if (path) {
      path.innerHTML = (active.nodes || [active.first, active.backend]).map((node, index) => (
        `${index ? '<span class="bankvault-route-arrow">→</span>' : ""}<span class="bankvault-route-node">${escapeHtml(node)}</span>`
      )).join("");
    }
    const log = document.getElementById("bankvaultFlowLog");
    if (log) {
      log.innerHTML = state.flowEvents.map((event) => (
        `<div class="bankvault-log-line"><span class="bankvault-log-time">[${escapeHtml(event.time)}]</span> step ${event.step}: ${escapeHtml(event.message)} <span>(${escapeHtml(event.action)})</span></div>`
      )).join("");
    }
    rows.innerHTML = workflowRows.map((row) => {
      const rowClass = row.step === state.activeWorkflowStep ? "active-step" : row.step < state.activeWorkflowStep ? "recent-step" : "";
      return `
        <tr class="${rowClass}">
          <td><span class="bankvault-flow-step">${row.step}</span></td>
          <td>${escapeHtml(row.action)}</td>
          <td>${escapeHtml(row.first)}</td>
          <td>${escapeHtml(row.backend)}</td>
          <td>${escapeHtml(row.data)}</td>
        </tr>`;
    }).join("");
    const status = document.getElementById("bankvaultFlowStatus");
    if (status) status.textContent = "Step " + state.activeWorkflowStep + ": " + state.workflowStatus;
  }

  function showTransferCard() {
    const transfer = document.getElementById("bankvaultTransferForm");
    const feature = document.getElementById("bankvaultFeatureView");
    if (feature) feature.classList.remove("active");
    if (transfer) {
      transfer.classList.add("active");
      transfer.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }

  function hideTransferCard() {
    document.getElementById("bankvaultTransferForm")?.classList.remove("active");
  }

  function showHome() {
    hideTransferCard();
    const feature = document.getElementById("bankvaultFeatureView");
    if (feature) {
      feature.classList.remove("active");
      feature.innerHTML = "";
    }
    document.querySelector(".app-header")?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function showFeature(name) {
    hideTransferCard();
    const view = document.getElementById("bankvaultFeatureView");
    if (!view) return;
    const content = {
      receive: `
        <div class="bankvault-feature-head"><h3>Receive Money</h3><button class="bankvault-close" type="button" data-bank-home>Close</button></div>
        <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>ACH / Wire Routing</span><strong>021000021</strong></div></div>
        <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>Default receiving account</span><strong>Everyday Checking</strong></div></div>
        <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>Payment link</span><strong>piggybank.me/${escapeHtml(state.credentials.username)}</strong></div></div>`,
      pay: `
        <div class="bankvault-feature-head"><h3>Utilities Payment</h3><button class="bankvault-close" type="button" data-bank-home>Close</button></div>
        <div class="bankvault-utility-grid">
          ${Object.entries(utilityBills).map(([item, bill]) => `
            <button class="bankvault-action" type="button" data-mock-pay="${item}">${bill.icon} ${item}<br><small>${cents(bill.amount_cents)}</small></button>
          `).join("")}
        </div>
        <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>Selected bill</span><strong id="bankvaultMockBill">Choose a utility</strong></div></div>`,
      analytics: `
        <div class="bankvault-feature-head"><h3>Income & Spending</h3><button class="bankvault-close" type="button" data-bank-home>Close</button></div>
        <div class="bankvault-grid-2">
          <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>Income</span><strong style="color:#059669">$7,850</strong></div><div class="bankvault-chart"><span class="bankvault-bar" style="height:65%"></span><span class="bankvault-bar" style="height:80%"></span><span class="bankvault-bar" style="height:55%"></span><span class="bankvault-bar" style="height:92%"></span><span class="bankvault-bar" style="height:74%"></span></div></div>
          <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>Spending</span><strong style="color:#dc2626">$3,240</strong></div><div class="bankvault-chart"><span class="bankvault-bar" style="height:48%;background:#fb7185"></span><span class="bankvault-bar" style="height:63%;background:#fb7185"></span><span class="bankvault-bar" style="height:44%;background:#fb7185"></span><span class="bankvault-bar" style="height:71%;background:#fb7185"></span><span class="bankvault-bar" style="height:52%;background:#fb7185"></span></div></div>
        </div>`,
      cards: `
        <div class="bankvault-feature-head"><h3>Cards</h3><button class="bankvault-action primary" type="button" data-add-card>Add Card</button></div>
        <div class="bankvault-mini-card" style="background:linear-gradient(135deg,#172033,#667eea);color:white"><div class="bankvault-card-row"><span>PIGGYBANK Platinum</span><strong>**** 4582</strong></div><div class="bankvault-progress"><span style="width:38%"></span></div><small>$1,520 used of $4,000</small></div>
        <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>Virtual Travel Card</span><strong>Frozen</strong></div></div>
        <div id="bankvaultAddedCards"></div>`,
      invest: `
        <div class="bankvault-feature-head"><h3>S&P 500 Watchlist</h3><button class="bankvault-close" type="button" data-bank-home>Close</button></div>
        ${[
          ["SPY", "S&P 500 ETF", "+0.42%"],
          ["AAPL", "Apple", "+1.12%"],
          ["MSFT", "Microsoft", "+0.86%"],
          ["NVDA", "NVIDIA", "+2.31%"],
          ["JPM", "JPMorgan Chase", "-0.18%"]
        ].map(([ticker, label, move]) => `<div class="bankvault-mini-card"><div class="bankvault-card-row"><span><strong>${ticker}</strong> ${label}</span><strong style="color:${move.startsWith("+") ? "#059669" : "#dc2626"}">${move}</strong></div></div>`).join("")}`,
      settings: `
        <div class="bankvault-feature-head"><h3>Settings</h3><button class="bankvault-close" type="button" data-bank-home>Close</button></div>
        <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>Theme</span><button class="bankvault-action" type="button" data-theme-toggle>Toggle Light/Dark</button></div></div>
        <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>Biometric login</span><strong>Enabled</strong></div></div>
        <div class="bankvault-mini-card"><div class="bankvault-card-row"><span>Transfer alerts</span><strong>Push + Email</strong></div></div>`,
    }[name] || "";
    view.innerHTML = content;
    view.classList.add("active");
    view.scrollIntoView({ behavior: "smooth", block: "center" });
    wireFeatureView();
  }

  function wireFeatureView() {
    document.querySelectorAll("[data-bank-home]").forEach((btn) => {
      btn.addEventListener("click", showHome);
    });
    document.querySelectorAll("[data-mock-pay]").forEach((btn) => {
      btn.addEventListener("click", () => {
        payMockUtility(btn.dataset.mockPay);
      });
    });
    document.querySelector("[data-add-card]")?.addEventListener("click", () => {
      const target = document.getElementById("bankvaultAddedCards");
      if (target) target.innerHTML = `<div class="bankvault-mini-card"><div class="bankvault-card-row"><span>New Virtual Card</span><strong>**** ${Math.floor(1000 + Math.random() * 8999)}</strong></div></div>` + target.innerHTML;
    });
    document.querySelector("[data-theme-toggle]")?.addEventListener("click", () => {
      document.body.classList.toggle("bankvault-light-theme");
    });
  }

  function wirePanel() {
    const panel = document.getElementById("bankvault-live-panel");
    if (!panel || panel.dataset.wired === "true") return;
    panel.dataset.wired = "true";
    document.querySelectorAll(".bankvault-tab").forEach((tab) => {
      tab.addEventListener("click", () => selectTab(tab.dataset.bankvaultTab));
    });
    wireUserButtons();
    document.getElementById("bankvaultRefreshBtn")?.addEventListener("click", () => loadBankingData(true, 9));
    document.getElementById("bankvaultLogoutBtn")?.addEventListener("click", logout);
    document.getElementById("bankvaultLoginForm")?.addEventListener("submit", async (event) => {
      event.preventDefault();
      markWorkflowStep(3, "Submitting credentials to Auth through API Gateway.");
      saveCredentials({
        username: document.getElementById("bankvaultLoginUsername").value.trim(),
        password: document.getElementById("bankvaultLoginPassword").value,
      });
      await loadBankingData(true, 4);
      selectTab("transfer");
    });
    document.getElementById("bankvaultRegisterForm")?.addEventListener("submit", registerAccount);
    document.getElementById("bankvaultTransferForm")?.addEventListener("submit", transferMoney);
    document.querySelector("[data-bank-close-transfer]")?.addEventListener("click", hideTransferCard);

    document.querySelector("[data-bank-action='send']")?.addEventListener("click", showTransferCard);
    document.querySelector("[data-bank-action='receive']")?.addEventListener("click", () => showFeature("receive"));
    document.querySelector("[data-bank-action='pay']")?.addEventListener("click", () => showFeature("pay"));
    document.querySelector("[data-bank-action='analytics']")?.addEventListener("click", () => showFeature("analytics"));

    const navItems = document.querySelectorAll(".bottom-nav .nav-item");
    navItems[0]?.addEventListener("click", showHome);
    navItems[1]?.addEventListener("click", () => showFeature("cards"));
    navItems[2]?.addEventListener("click", () => showFeature("invest"));
    navItems[3]?.addEventListener("click", () => showFeature("settings"));
  }

  function renderTransactions(transactions) {
    const list = document.querySelector(".transaction-list");
    if (!list || !Array.isArray(transactions)) return;
    list.innerHTML = transactions.slice(0, 5).map((tx, index) => {
      const direction = tx.direction === "credit" ? "income" : "expense";
      const amountClass = tx.direction === "credit" ? "positive" : "negative";
      const sign = tx.direction === "credit" ? "+" : "-";
      return `
        <div class="transaction-item" style="animation-delay:${1.1 + index / 10}s">
          <div class="tx-icon ${direction}">${tx.direction === "credit" ? "💰" : "💸"}</div>
          <div class="tx-details">
            <div class="tx-name">${escapeHtml(tx.description)}</div>
            <div class="tx-date">${new Date(tx.created_at).toLocaleString()}</div>
          </div>
          <div class="tx-amount ${amountClass}">${sign}${cents(tx.amount_cents)}</div>
        </div>`;
    }).join("");
  }

  function prependMockTransaction(description, amountCents) {
    const list = document.querySelector(".transaction-list");
    if (!list) return;
    const item = document.createElement("div");
    item.className = "transaction-item";
    item.innerHTML = `
      <div class="tx-icon expense">💸</div>
      <div class="tx-details">
        <div class="tx-name">${escapeHtml(description)}</div>
        <div class="tx-date">${new Date().toLocaleString()}</div>
      </div>
      <div class="tx-amount negative">-${cents(amountCents)}</div>
    `;
    list.prepend(item);
  }

  function adjustDisplayedBalance(amountCents) {
    const balance = document.getElementById("balanceAmount");
    if (!balance) return;
    const current = Number.parseFloat(balance.textContent.replace(/[$,]/g, ""));
    if (!Number.isFinite(current)) return;
    balance.textContent = cents(Math.max(0, Math.round(current * 100) - amountCents));
  }

  function payMockUtility(name) {
    const billInfo = utilityBills[name];
    if (!billInfo) return;
    const bill = document.getElementById("bankvaultMockBill");
    if (bill) bill.textContent = `${name} paid ${cents(billInfo.amount_cents)}`;
    prependMockTransaction(`${name} utility payment - PIGGYBANK mock`, billInfo.amount_cents);
    adjustDisplayedBalance(billInfo.amount_cents);
    setStatus(`${name} mock payment posted for ${cents(billInfo.amount_cents)}.`, "ok");
    markWorkflowStep(6, `Mock ${name} payment posted in mobile UI for ${cents(billInfo.amount_cents)}.`);
  }

  function renderAccountPicker(accounts) {
    const select = document.getElementById("bankvaultFromAccount");
    if (select && Array.isArray(accounts)) {
      select.innerHTML = accounts.map((account) => (
        `<option value="${escapeHtml(account.id)}">${escapeHtml(account.name)} - ${cents(account.balance_cents)}</option>`
      )).join("");
    }
    const loginAccount = document.getElementById("bankvaultLoginAccount");
    if (loginAccount && Array.isArray(accounts) && accounts.length) {
      const checking = accounts.find((account) => account.type === "checking") || accounts[0];
      loginAccount.value = checking.id;
    }
  }

  function renderRecipientPicker(recipients) {
    const select = document.getElementById("bankvaultToUsername");
    if (!select) return;
    const current = String(state.credentials.username || "").toLowerCase();
    const options = (Array.isArray(recipients) && recipients.length ? recipients : [
      { username: state.credentials.username === "alice" ? "alex" : "alice", name: state.credentials.username === "alice" ? "Alex Morgan" : "Alice Chen" },
    ]).filter((recipient) => String(recipient.username || "").toLowerCase() !== current);
    select.innerHTML = options.map((recipient) => (
      `<option value="${escapeHtml(recipient.username)}">${escapeHtml(recipient.name || recipient.username)} (${escapeHtml(recipient.username)})</option>`
    )).join("");
  }

  function addPickerOption(select, value, label) {
    if (!select || !value) return;
    const exists = Array.from(select.options).some((option) => option.value === value);
    if (exists) return;
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label || value;
    select.appendChild(option);
  }

  function ensureFallbackPickers() {
    const from = document.getElementById("bankvaultFromAccount");
    if (from && !from.options.length) {
      addPickerOption(from, "acct-checking", "Everyday Checking - $24,426.80");
      addPickerOption(from, "acct-savings", "Savings - $136.00");
    }
    const to = document.getElementById("bankvaultToUsername");
    if (to && !to.options.length) {
      const current = String(state.credentials.username || "").toLowerCase();
      const users = normalizeUsers(state.recipients);
      users.forEach((user) => {
        if (String(user.username || "").toLowerCase() !== current) {
          addPickerOption(to, user.username, `${user.name || user.username} (${user.username})`);
        }
      });
      if (!to.options.length) {
        addPickerOption(to, current === "alice" ? "alex" : "alice", current === "alice" ? "Alex Morgan (alex)" : "Alice Chen (alice)");
      }
    }
  }

  function normalizeUsers(recipients) {
    const seen = new Set();
    const users = [];
    const add = (user) => {
      const username = String(user.username || "").trim();
      if (!username || seen.has(username.toLowerCase())) return;
      seen.add(username.toLowerCase());
      users.push({
        username,
        name: user.name || username,
      });
    };
    if (state.credentials.username) {
      add({
        username: state.credentials.username,
        name: state.summary && state.summary.customer ? state.summary.customer.name : state.credentials.username,
      });
    }
    (recipients || []).forEach(add);
    ["alex", "alice"].forEach((username) => {
      add({ username, name: username === "alex" ? "Alex Morgan" : "Alice Chen" });
    });
    return users.sort((a, b) => a.username.localeCompare(b.username));
  }

  function ensureLoginUserSelect() {
    const current = document.getElementById("bankvaultLoginUsername");
    if (!current || current.tagName === "SELECT") return current;
    const select = document.createElement("select");
    select.id = current.id;
    select.name = current.name || "username";
    select.value = current.value || state.credentials.username;
    current.replaceWith(select);
    return select;
  }

  function renderUserControls() {
    state.users = normalizeUsers(state.recipients);
    const loginSelect = ensureLoginUserSelect();
    if (loginSelect) {
      const selected = state.credentials.username || loginSelect.value || "alex";
      loginSelect.innerHTML = state.users.map((user) => (
        `<option value="${escapeHtml(user.username)}">${escapeHtml(user.name)} (${escapeHtml(user.username)})</option>`
      )).join("");
      loginSelect.value = state.users.some((user) => user.username === selected) ? selected : state.users[0]?.username || selected;
    }

    const shortcuts = document.querySelector(".bankvault-shortcuts");
    if (shortcuts) {
      shortcuts.innerHTML = state.users.map((user) => {
        const pass = ["alex", "alice"].includes(user.username.toLowerCase()) ? "demo" : "";
        return `<button type="button" data-switch-user="${escapeHtml(user.username)}" data-switch-pass="${escapeHtml(pass)}">${escapeHtml(user.username)}</button>`;
      }).join("") + '<button type="button" id="bankvaultRefreshBtn">Refresh</button>';
      wireUserButtons();
    }
  }

  function wireUserButtons() {
    document.querySelectorAll("[data-switch-user]").forEach((btn) => {
      if (btn.dataset.wired === "true") return;
      btn.dataset.wired = "true";
      btn.addEventListener("click", async () => {
        const loginUser = document.getElementById("bankvaultLoginUsername");
        const loginPass = document.getElementById("bankvaultLoginPassword");
        if (loginUser) loginUser.value = btn.dataset.switchUser;
        if (loginPass) loginPass.value = btn.dataset.switchPass || "";
        if (btn.dataset.switchPass) {
          saveCredentials({ username: btn.dataset.switchUser, password: btn.dataset.switchPass });
          await loadBankingData(true, 4);
        } else {
          setStatus("Selected " + btn.dataset.switchUser + ". Enter that user's password and log in.", "ok");
          selectTab("login");
        }
      });
    });
    const refresh = document.getElementById("bankvaultRefreshBtn");
    if (refresh && refresh.dataset.wired !== "true") {
      refresh.dataset.wired = "true";
      refresh.addEventListener("click", () => loadBankingData(true, 9));
    }
  }

  async function loadRecipients(token) {
    try {
      const body = await api("/api/recipients/list", {
        headers: { Authorization: "Bearer " + token },
      });
      state.recipients = body.recipients || [];
      renderRecipientPicker(state.recipients);
      renderUserControls();
    } catch (err) {
      renderRecipientPicker(state.recipients);
      renderUserControls();
      console.warn("Recipient list unavailable:", err);
    }
  }

  function logout() {
    sessionStorage.removeItem("bankvault_token");
    state.token = "";
    setStatus("Logged out. Sign in to continue.", "ok");
    selectTab("login");
    hideTransferCard();
    const feature = document.getElementById("bankvaultFeatureView");
    if (feature) feature.classList.remove("active");
    markWorkflowStep(3, "Local token cleared; login required before new API actions.");
  }

  async function loadBankingData(forceLogin, workflowStep) {
    try {
      markWorkflowStep(3, "POST /api/login -> API Gateway -> Auth -> DB credential read.");
      const token = await login(forceLogin);
      const step = workflowStep || 4;
      markWorkflowStep(step, step === 9 ? "GET /api/mobile/summary -> updated balances and transactions." : "GET /api/mobile/summary -> profile, accounts, balances, transactions.");
      const summary = await api("/api/mobile/summary", {
        headers: { Authorization: "Bearer " + token },
      });
      state.summary = summary;
      const firstName = summary.customer && summary.customer.name ? summary.customer.name.split(" ")[0] : state.credentials.username;
      const greeting = document.querySelector(".user-greeting h2");
      if (greeting) greeting.textContent = "Good Morning, " + firstName;
      const avatar = document.querySelector(".profile-avatar");
      if (avatar) avatar.textContent = firstName.slice(0, 1).toUpperCase();
      const user = document.getElementById("bankvaultCurrentUser");
      if (user) user.textContent = "Signed in as " + state.credentials.username;
      const balance = document.getElementById("balanceAmount");
      if (balance) balance.textContent = cents(summary.total_balance_cents);
      renderAccountPicker(summary.accounts || []);
      await loadRecipients(token);
      renderTransactions(summary.recent_transactions || []);
      setStatus("Account data live. Ready for transfers.", "ok");
    } catch (err) {
      ensureFallbackPickers();
      setStatus(err.message || "Banking API unavailable", "err");
      console.warn("BankVault API data unavailable:", err);
    }
  }

  async function registerAccount(event) {
    event.preventDefault();
    markWorkflowStep(2, "Creating customer, credentials, accounts, and opening deposit.");
    const username = document.getElementById("bankvaultRegUsername").value.trim();
    const password = document.getElementById("bankvaultRegPassword").value || "demo";
    const name = document.getElementById("bankvaultRegName").value.trim();
    const email = document.getElementById("bankvaultRegEmail").value.trim();
    const deposit = centsFromDollars(document.getElementById("bankvaultRegDeposit").value);
    try {
      markWorkflowStep(2, "POST /api/customers -> create customer, credentials, accounts, opening deposit.");
      await api("/api/customers", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          username,
          password,
          name,
          email,
          opening_deposit_cents: deposit || 50000,
        }),
      });
      saveCredentials({ username, password });
      await loadBankingData(true, 4);
      selectTab("transfer");
      setStatus("Created " + username + " and signed in.", "ok");
    } catch (err) {
      setStatus("Register failed: " + err.message, "err");
    }
  }

  async function transferMoney(event) {
    event.preventDefault();
    const token = await login();
    const fromAccount = document.getElementById("bankvaultFromAccount").value;
    const toUsername = document.getElementById("bankvaultToUsername").value.trim();
    const amountCents = centsFromDollars(document.getElementById("bankvaultAmount").value);
    const description = document.getElementById("bankvaultDescription").value.trim() || "Mobile transfer";
    if (!fromAccount || !toUsername || amountCents <= 0) {
      setStatus("Choose an account, recipient, and positive amount.", "err");
      return;
    }
    try {
      markWorkflowStep(5, "Validating recipient username through Core Banking.");
      const recipient = await api("/api/recipients?username=" + encodeURIComponent(toUsername), {
        headers: { Authorization: "Bearer " + token },
      });
      markWorkflowStep(6, "POST /api/transfers -> Ledger debits source and credits recipient.");
      await api("/api/transfers", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer " + token,
        },
        body: JSON.stringify({
          from_account_id: fromAccount,
          to_username: toUsername,
          amount_cents: amountCents,
          description,
        }),
      });
      markWorkflowStep(7, "Ledger -> Audit Service -> DB audit trail created.");
      markWorkflowStep(8, "Ledger -> Notification Service -> DB notification created.");
      await loadBankingData(true, 9);
      setStatus("Sent " + cents(amountCents) + " to " + recipient.recipient.name + ".", "ok");
    } catch (err) {
      setStatus("Transfer failed: " + err.message, "err");
    }
  }

  async function loadGatewayMetrics() {
    const metrics = await api("/api/server-metrics");
    const serverIP = document.getElementById("serverIP");
    const responseTime = document.getElementById("responseTime");
    const connectionCount = document.getElementById("connectionCount");
    const lbStatus = document.getElementById("lbStatus");
    if (serverIP) serverIP.textContent = window.location.hostname || metrics.server;
    if (responseTime) responseTime.textContent = metrics.response_time_ms + " ms";
    if (connectionCount) connectionCount.textContent = metrics.connections;
    if (lbStatus) {
      lbStatus.textContent = "API " + metrics.lb_status + " ✓";
      lbStatus.style.color = "#00ff88";
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    injectStyles();
    injectExternalDevView();
    injectPanel();
    loadBankingData().catch((err) => console.warn("BankVault API data unavailable:", err));
    loadGatewayMetrics().catch((err) => console.warn("BankVault API metrics unavailable:", err));
    setInterval(() => loadGatewayMetrics().catch(() => {}), 10000);
  });
})();
