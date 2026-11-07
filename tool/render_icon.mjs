// Renders assets/icon/*.svg to 1024px PNGs with headless Edge or Chrome.
// Usage: node tool/render_icon.mjs
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const browsers = [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
];
const browser = browsers.find(existsSync);
if (!browser) throw new Error('Edge or Chrome not found');

const jobs = [
  ['assets/icon/icon.svg', 'assets/icon/icon.png', 'ffffffff'],
  ['assets/icon/foreground.svg', 'assets/icon/foreground.png', '00000000'],
];

for (const [svgPath, pngPath, bg] of jobs) {
  const svg = readFileSync(svgPath, 'utf8');
  const dir = mkdtempSync(join(tmpdir(), 'icon-'));
  const html = join(dir, 'p.html');
  writeFileSync(
    html,
    `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:transparent}svg{display:block}</style>${svg}`,
  );
  execFileSync(browser, [
    '--headless=new',
    '--disable-gpu',
    '--hide-scrollbars',
    `--default-background-color=${bg}`,
    '--window-size=1024,1024',
    `--screenshot=${resolve(pngPath)}`,
    `file:///${html.replace(/\\/g, '/')}`,
  ]);
  console.log('wrote', pngPath);
}
