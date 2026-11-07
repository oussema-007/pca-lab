// Real browser (Chromium via k6/browser): login form -> web client -> Sales orders list.
// Used to size the rate limit (how many requests does a real user page load generate?).
import { browser } from 'k6/browser';
export const options = { scenarios: { ui: { executor: 'shared-iterations', iterations: 1, options: { browser: { type: 'chromium' } } } } };
export default async function () {
  const page = await browser.newPage();
  try {
    await page.goto(`${__ENV.BASE}/web/login`, { waitUntil: 'networkidle' });
    await page.locator('input[name="login"]').type('vendeur1');
    await page.locator('input[name="password"]').type(__ENV.PCA_PW1);
    await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle' }), page.locator('button[type="submit"]').click()]);
    console.log('MARK logged-in url=' + page.url());
    await page.goto(`${__ENV.BASE}/web#action=sale.action_orders`, { waitUntil: "networkidle" });
    await page.locator(".o_list_view, .o_kanban_view").waitFor({ timeout: 15000 });
    await page.waitForTimeout(1500);
    console.log('MARK sales url=' + page.url());
    await page.screenshot({ path: __ENV.SHOT || 'sales.png' });
  } finally { await page.close(); }
}
