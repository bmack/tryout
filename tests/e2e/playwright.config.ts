import { defineConfig, devices } from '@playwright/test';

// DDEV serves over HTTPS with a locally-issued mkcert certificate. Chromium does
// not trust it unless mkcert's root CA is in the system store, and a contributor
// running these for the first time will not have it — so accept it explicitly
// rather than making the suite fail for a reason unrelated to what it tests.
export default defineConfig({
  testDir: '.',
  timeout: 60_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,          // one TYPO3 install per site; keep logins serial
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? 'list' : [['list']],
  use: {
    ignoreHTTPSErrors: true,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
});
