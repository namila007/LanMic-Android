import { test, expect } from '@playwright/test';

const WIDTHS = [320, 375, 768, 1024, 1440, 1920];

test('page renders key content', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('h1')).toContainText('Your phone is the microphone');
  await expect(page.getByRole('link', { name: 'Download for Android' })).toHaveAttribute('href', /releases\/latest$/);
  await expect(page.locator('#faq details')).toHaveCount(7);
});

test('sliders show the limiter at +12 dB', async ({ page }) => {
  await page.goto('/');
  await page.locator('#mic').fill('12');
  await expect(page.getByText('Too loud, limiting')).toBeVisible();
});

for (const w of WIDTHS) {
  test(`no horizontal overflow and screenshot at ${w}px`, async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' }); // scroll reveals never fire in full-page captures
    await page.setViewportSize({ width: w, height: 900 });
    await page.goto('/');
    const over = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(over).toBeLessThanOrEqual(0);
    await page.screenshot({ path: `shots/home-${w}.png`, fullPage: true });
  });
}
