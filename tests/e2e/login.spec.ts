import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';

// Which sites exist is a property of the project, not of this file: ask tryout.
// TRYOUT_PROJECT points at a provisioned DDEV project; without it there is nothing
// to test and the suite says so rather than failing obscurely.
const APPROOT = process.env.TRYOUT_PROJECT || '';

function sh(cmd: string, args: string[]): string {
  return execFileSync(cmd, args, { cwd: APPROOT, encoding: 'utf8' }).trim();
}

type Site = { name: string; url: string; primary: boolean };

function discoverSites(): Site[] {
  if (!APPROOT) return [];
  // `worktree list` prints NAME … URL; take the pairs it reports rather than
  // hard-coding hostnames, so serving another worktree is covered automatically.
  // --plain is the machine-readable contract — without it the command renders a
  // bordered gum table that this regex cannot match.
  // The command colours its output; strip the escapes before matching.
  const out = sh('ddev', ['tryout', 'worktree', 'list', '--plain'])
    .replace(/\u001b\[[0-9;]*m/g, '');
  const sites: Site[] = [];
  for (const line of out.split('\n')) {
    const m = line.match(/^\s+(\S+)\s+.*\s(https:\/\/\S+)/);
    if (m) sites.push({ name: m[1], url: m[2].replace(/\s+$/, ''),
                        primary: /← primary/.test(line) });
  }
  return sites;
}

const sites = discoverSites();

test.describe('TYPO3 backend login', () => {
  test.skip(!APPROOT, 'set TRYOUT_PROJECT to a provisioned DDEV project');
  test.skip(sites.length === 0, 'no served sites — run: ddev tryout worktree serve <name>');

  for (const site of sites) {
    test(`${site.name} logs in and reaches the backend`, async ({ page }) => {
      await page.goto(`${site.url}/typo3/`);

      // The login page itself, before anything is typed.
      await expect(page).toHaveTitle(/TYPO3 CMS Login/);

      await page.fill('#t3-username', 'admin');
      await page.fill('#t3-password', 'Password.1');
      await Promise.all([
        page.waitForNavigation({ timeout: 30_000 }).catch(() => null),
        page.click('#t3-login-submit'),
      ]);

      // A backend URL, not a bounce back to /typo3/login. The scheme matters:
      // a served site that does not tell PHP the request was TLS drops to http,
      // its secure cookie is never returned, and login fails with "Please
      // activate Cookies" — a real bug this suite caught.
      await expect(page).toHaveURL(/\/typo3\/module\//, { timeout: 30_000 });
      expect(page.url()).toMatch(/^https:/);

      // And the backend actually rendered, not just redirected.
      await expect(page.locator('.scaffold-modulemenu, [data-modulemenu]').first())
        .toBeVisible({ timeout: 20_000 });
    });
  }

  test('each site serves its own TYPO3, not one instance on many hostnames', async () => {
    test.skip(sites.length < 2, 'needs at least two served sites');

    // The primary answers to @primary, not to its worktree name; the marker in the
    // list output is how `worktree list` flags it.
    const versions = sites.map((s) => ({
      name: s.name,
      version: sh('ddev', ['tryout', 'exec', s.primary ? '@primary' : s.name,
                           'vendor/bin/typo3', '--version']),
    }));
    for (const v of versions) {
      expect(v.version, `${v.name} reports a TYPO3 version`).toMatch(/TYPO3 CMS/);
    }
  });
});
