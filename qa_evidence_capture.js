const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const baseUrl = process.env.BASE_URL || 'http://192.168.1.157:8080';
const user = process.env.LUCI_USER || 'root';
const pass = process.env.LUCI_PASS || 'password';
const phase = process.env.PHASE || 'pre';
const outDir = process.env.OUT_DIR || path.join(process.cwd(), 'qa_evidence', `p0_${new Date().toISOString().replace(/[:]/g, '-').replace(/\..+/, '')}`);

fs.mkdirSync(outDir, { recursive: true });

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: '/usr/bin/google-chrome-stable',
    args: ['--no-sandbox', '--disable-dev-shm-usage']
  });

  const context = await browser.newContext({ viewport: { width: 1600, height: 1200 } });
  const page = await context.newPage();

  const networkHits = [];
  const failedResponses = [];
  const consoleErrors = [];
  const consoleAll = [];
  const pageErrors = [];

  page.on('response', async (res) => {
    const url = res.url();
    const status = res.status();
    const item = {
      url,
      status,
      statusText: res.statusText(),
      resourceType: res.request().resourceType(),
      time: new Date().toISOString()
    };

    if (url.includes('/luci-static/resources/view/phantun/config.js')) {
      networkHits.push(item);
    }

    if (status >= 400) {
      failedResponses.push(item);
    }
  });

  page.on('console', (msg) => {
    const item = { type: msg.type(), text: msg.text(), time: new Date().toISOString() };
    consoleAll.push(item);
    if (msg.type() === 'error') consoleErrors.push(item);
  });

  page.on('pageerror', (err) => {
    pageErrors.push({ message: String(err), time: new Date().toISOString() });
  });

  // Login page
  await page.goto(`${baseUrl}/cgi-bin/luci/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(1200);
  await page.screenshot({ path: path.join(outDir, `${phase}_01_login_page.png`), fullPage: true });

  // Login action
  await page.fill('#luci_username', user);
  await page.fill('#luci_password', pass);
  const loginBtn = page.locator('button:has-text("Log in"), button:has-text("Login"), .cbi-button-positive.important').first();
  await loginBtn.click();
  await page.waitForTimeout(2000);
  await page.screenshot({ path: path.join(outDir, `${phase}_01b_login_success.png`), fullPage: true });

  // Reset runtime logs after login to avoid unauth noise from login page
  networkHits.length = 0;
  failedResponses.length = 0;
  consoleErrors.length = 0;
  consoleAll.length = 0;
  pageErrors.length = 0;

  // Open phantun page
  await page.goto(`${baseUrl}/cgi-bin/luci/admin/services/phantun`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(3500);
  await page.screenshot({ path: path.join(outDir, `${phase}_02_phantun_page.png`), fullPage: true });

  const warningCount = await page.locator('text=Phantun Not Installed').count();
  const noPwdWarnCount = await page.locator('text=No password set!').count();

  // Try save & apply: toggle one checkbox then click save/apply button if present
  let saveApplyClicked = false;
  let saveApplyError = null;
  try {
    const cbs = page.locator('input[type="checkbox"]');
    const cbCount = await cbs.count();
    if (cbCount > 0) {
      await cbs.nth(0).click({ force: true });
      await page.waitForTimeout(500);
    }

    let saveBtn = page.getByRole('button', { name: /Save\s*&\s*Apply|Save and Apply|Apply/i }).first();
    if (await saveBtn.count() === 0) {
      saveBtn = page.locator('.cbi-page-actions .cbi-button, .cbi-button-apply, .cbi-button-save').filter({ hasText: /Save|Apply/i }).first();
    }

    if (await saveBtn.count() > 0) {
      await saveBtn.click({ force: true });
      saveApplyClicked = true;
      await page.waitForTimeout(3000);
    }
  } catch (e) {
    saveApplyError = String(e);
  }

  await page.screenshot({ path: path.join(outDir, `${phase}_05_save_apply.png`), fullPage: true });

  // Build network report screenshot
  const report = await context.newPage();
  const latestNet = networkHits[networkHits.length - 1] || null;
  const netStatus = latestNet ? latestNet.status : 'N/A';
  await report.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>
    body{font-family:Arial,Helvetica,sans-serif;padding:24px;background:#111;color:#eee}
    h1{margin:0 0 16px 0;font-size:22px}
    .ok{color:#67e480}.bad{color:#ff6b6b}
    table{border-collapse:collapse;width:100%;margin-top:12px}
    td,th{border:1px solid #444;padding:8px;text-align:left;font-size:14px}
  </style></head><body>
  <h1>Network Evidence (${phase})</h1>
  <div>Target: <code>/luci-static/resources/view/phantun/config.js</code></div>
  <div>Status: <b class="${netStatus === 200 ? 'ok' : 'bad'}">${netStatus}</b></div>
  <table><tr><th>Time</th><th>Status</th><th>URL</th></tr>
  ${(networkHits.length ? networkHits : [{time:'-',status:'N/A',url:'No hit captured'}]).map(h=>`<tr><td>${h.time}</td><td>${h.status}</td><td>${h.url}</td></tr>`).join('')}
  </table>
  </body></html>`);
  await report.screenshot({ path: path.join(outDir, `${phase}_03_network_configjs_200.png`), fullPage: true });

  // Console report screenshot
  const consolePage = await context.newPage();
  const criticalConsoleErrors = consoleErrors.filter(c => !/favicon\.ico|logo\.png|apple-touch-icon|bootstrap\.css|mobile\.css/i.test(c.text));
  const criticalFailedResponses = failedResponses.filter(r => {
    if (r.status === 403 && /\/cgi-bin\/luci\/admin\/(translations|menu)/i.test(r.url)) return false;
    if (r.status === 404 && /favicon\.ico|apple-touch-icon|logo\.png/i.test(r.url)) return false;
    return true;
  });

  await consolePage.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>
    body{font-family:Arial,Helvetica,sans-serif;padding:24px;background:#111;color:#eee}
    h1{margin:0 0 16px 0;font-size:22px}
    .ok{color:#67e480}.bad{color:#ff6b6b}
    table{border-collapse:collapse;width:100%;margin-top:12px}
    td,th{border:1px solid #444;padding:8px;text-align:left;font-size:13px;vertical-align:top}
    .mono{font-family:Consolas,Menlo,monospace}
  </style></head><body>
  <h1>Console/Network Evidence (${phase})</h1>
  <div>Critical console errors: <b class="${(criticalConsoleErrors.length + pageErrors.length) === 0 ? 'ok' : 'bad'}">${criticalConsoleErrors.length + pageErrors.length}</b></div>
  <div>Critical failed responses (HTTP >=400): <b class="${criticalFailedResponses.length === 0 ? 'ok' : 'bad'}">${criticalFailedResponses.length}</b></div>

  <h3>Critical console error events</h3>
  <table><tr><th>Time</th><th>Type</th><th>Message</th></tr>
  ${(criticalConsoleErrors.length ? criticalConsoleErrors : [{time:'-',type:'none',text:'No critical console error captured'}]).map(c=>`<tr><td>${c.time}</td><td>${c.type}</td><td class="mono">${String(c.text).replace(/</g,'&lt;')}</td></tr>`).join('')}
  </table>

  <h3>Critical failed responses</h3>
  <table><tr><th>Time</th><th>Status</th><th>Type</th><th>URL</th></tr>
  ${(criticalFailedResponses.length ? criticalFailedResponses : [{time:'-',status:'none',resourceType:'-',url:'No critical failed response captured'}]).map(r=>`<tr><td>${r.time}</td><td>${r.status}</td><td>${r.resourceType}</td><td class="mono">${String(r.url).replace(/</g,'&lt;')}</td></tr>`).join('')}
  </table>

  <h3>PageError events</h3>
  <table><tr><th>Time</th><th>Message</th></tr>
  ${(pageErrors.length ? pageErrors : [{time:'-',message:'No pageerror captured'}]).map(e=>`<tr><td>${e.time}</td><td class="mono">${String(e.message).replace(/</g,'&lt;')}</td></tr>`).join('')}
  </table>
  </body></html>`);
  await consolePage.screenshot({ path: path.join(outDir, `${phase}_04_console_no_critical_error.png`), fullPage: true });

  const summary = {
    phase,
    baseUrl,
    outDir,
    warningCount,
    noPwdWarnCount,
    networkHits,
    failedResponses,
    criticalFailedResponses,
    consoleErrors,
    criticalConsoleErrors,
    pageErrors,
    saveApplyClicked,
    saveApplyError,
    generatedAt: new Date().toISOString()
  };

  fs.writeFileSync(path.join(outDir, `${phase}_summary.json`), JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary, null, 2));

  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
