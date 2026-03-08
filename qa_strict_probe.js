const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: '/usr/bin/google-chrome-stable', args: ['--no-sandbox','--disable-dev-shm-usage'] });
  const page = await browser.newPage({ viewport: { width: 1600, height: 1200 } });
  const errors = [];
  const failed = [];
  page.on('console', msg => { if (msg.type() === 'error') errors.push(msg.text()); });
  page.on('pageerror', err => errors.push(String(err)));
  page.on('response', res => { if (res.status() >= 400) failed.push({url: res.url(), status: res.status(), type: res.request().resourceType()}); });

  const base = 'http://localhost:8080';
  await page.goto(base + '/cgi-bin/luci/', { waitUntil: 'domcontentloaded' });
  await page.fill('#luci_username', 'root');
  await page.fill('#luci_password', 'password');
  await page.locator('button:has-text("Log in"), button:has-text("Login"), .cbi-button-positive.important').first().click();
  await page.waitForTimeout(1500);

  // reset noise post-login
  errors.length = 0; failed.length = 0;

  const result = { pages: {} };

  // system page
  await page.goto(base + '/cgi-bin/luci/admin/system/system', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(3000);
  result.pages.system = {
    title: await page.title(),
    bodyHasRPCError: await page.locator('text=/RPCError|RPC error|Unhandled token|TypeError/i').count(),
    bodyHasQuestionBrand: await page.locator('header, .brand, .logo, .navbar-brand, #header').evaluateAll(els => els.map(e => e.innerText || e.textContent || '').join(' | ')).catch(() => ''),
    h1: await page.locator('h1,h2,.main h3').allTextContents().catch(() => []),
  };

  // phantun config
  errors.length = 0; failed.length = 0;
  await page.goto(base + '/cgi-bin/luci/admin/services/phantun/config', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(3500);
  result.pages.config = {
    title: await page.title(),
    hasPromiseText: await page.locator('text="[object Promise]"').count(),
    hasLoadingStuck: await page.locator('text=/Loading view|Loading…/i').count(),
    bodyTextSample: (await page.locator('body').innerText()).slice(0, 3000),
    failedResponses: failed,
    consoleErrors: errors,
    addServer: await page.locator('text=/Add Server|Add server instance/i').count(),
    addClient: await page.locator('text=/Add Client|Add client instance/i').count(),
  };

  // phantun status
  errors.length = 0; failed.length = 0;
  await page.goto(base + '/cgi-bin/luci/admin/services/phantun/status', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(3500);
  result.pages.status = {
    title: await page.title(),
    hasPromiseText: await page.locator('text="[object Promise]"').count(),
    hasLoadingStuck: await page.locator('text=/Loading view|Loading…/i').count(),
    bodyTextSample: (await page.locator('body').innerText()).slice(0, 3000),
    failedResponses: failed,
    consoleErrors: errors,
    serviceRunning: await page.locator('text=/Running|Stopped/i').count(),
  };

  // pollution/menu text scan from homepage/menu area
  await page.goto(base + '/cgi-bin/luci/', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2500);
  const body = await page.locator('body').innerText();
  result.pollution = {
    poweroffdevice: /Power Off Device/i.test(body),
    udpSpeeder: /udp-speeder|UDP Speeder/i.test(body),
    udpTunnel: /udp-tunnel|UDP Tunnel/i.test(body),
    udp2raw: /udp2raw/i.test(body)
  };

  console.log(JSON.stringify(result, null, 2));
  await browser.close();
})();
