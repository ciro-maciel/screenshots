#!/usr/bin/env bun
// Regenerates everything in Resources/ that comes from outside this folder:
//   - Montserrat (OFL, from its upstream repository), the only interface family
//   - Tabler icons (MIT), stroke 1.5, as template PDFs (outline; a few filled for the shape tools)
//   - the app icon: the letter S, through the public favicon tool at ciromaciel.click/tools
//     (Candal, 555555 on white, size 60)
//   - the menu bar glyph: the same square with the S cut out, as a template
//
// Resources/ is committed, so a build never needs this script.
//
//   bun scripts/assets.mjs
//
// Needs rsvg-convert (brew install librsvg), sips and iconutil (both ship with macOS).

import { $ } from 'bun';
import { mkdirSync, writeFileSync, copyFileSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const RES = join(ROOT, 'Resources');

// --- fonts -----------------------------------------------------------------
const FONT_WEIGHTS = ['Regular', 'Medium', 'Bold', 'ExtraBold', 'Black'];
mkdirSync(join(RES, 'Fonts'), { recursive: true });
for (const w of FONT_WEIGHTS) {
  const file = `Montserrat-${w}.ttf`;
  const url = `https://github.com/JulietaUla/Montserrat/raw/master/fonts/ttf/${file}`;
  writeFileSync(join(RES, 'Fonts', file), Buffer.from(await (await fetch(url)).arrayBuffer()));
}
console.log(`fonts: ${FONT_WEIGHTS.length}`);

// --- Tabler icons ------------------------------------------------------------
const OUTLINE = [
  // menu and capture modes
  'screenshot', 'camera', 'crosshair', 'app-window', 'device-desktop', 'arrow-autofit-height',
  'text-recognition', 'clock-hour-4', 'player-record', 'player-stop', 'video', 'gif', 'history',
  'eye-off', 'eye', 'settings', 'power', 'photo', 'microphone', 'volume', 'mouse',
  // editor
  'pointer', 'crop', 'square', 'circle', 'slash', 'arrow-up-right', 'typography', 'pencil',
  'highlight', 'circle-number-1', 'blur', 'focus-2', 'background', 'arrow-back-up',
  'arrow-forward-up', 'trash', 'copy', 'device-floppy', 'pin', 'pinned', 'zoom-in', 'zoom-out',
  'drag-drop', 'download', 'check', 'x', 'minus', 'plus', 'maximize',
  // settings and states
  'adjustments', 'wallpaper', 'keyboard', 'layout-dashboard', 'info-circle', 'folder',
  'alert-circle', 'external-link', 'clock', 'lock', 'chevron-down', 'shield-check', 'refresh',
  'grip-vertical', 'grip-horizontal',
];
const FILLED = ['square', 'circle'];
mkdirSync(join(RES, 'Icons'), { recursive: true });
const tmp = join(tmpdir(), 'screenshots-assets');
mkdirSync(tmp, { recursive: true });
async function icon(style, name, out) {
  let svg = await (await fetch(`https://unpkg.com/@tabler/icons@3.19.0/icons/${style}/${name}.svg`)).text();
  // Our standard: stroke 1.5; black so the PDF works as a template image.
  svg = svg.replace('stroke-width="2"', 'stroke-width="1.5"')
    .replace('stroke="currentColor"', 'stroke="#000000"')
    .replace('fill="currentColor"', 'fill="#000000"');
  const src = join(tmp, `${out}.svg`);
  writeFileSync(src, svg);
  await $`rsvg-convert -f pdf -o ${join(RES, 'Icons', `${out}.pdf`)} ${src}`.quiet();
}
for (const name of OUTLINE) await icon('outline', name, name);
for (const name of FILLED) await icon('filled', name, `${name}-filled`);
console.log(`icons: ${OUTLINE.length + FILLED.length}`);

// --- illustrations ------------------------------------------------------------
// None in this repository: the ones in the official build come from a licensed stock gallery
// that can't be redistributed. Without them, each place draws the Tabler icon of the same idea
// (Illustration in Sources/Screenshots/UI/Theme.swift). To use your own, drop 560 x 560 PNGs
// named camera, access and editor into Resources/Illustrations.

// --- app icon ------------------------------------------------------------------
const res = await fetch('https://mcp.tools.ciromaciel.click', {
  method: 'POST',
  headers: { 'User-Agent': 'curl/8.7.1', 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
  body: JSON.stringify({
    jsonrpc: '2.0', id: 1, method: 'tools/call',
    params: { name: 'generate_favicon', arguments: { mode: 'text', text: 'S', font: 'Candal', background: 'ffffff', color: '555555', size: 60, adaptive: false } },
  }),
});
let raw = await res.text();
if (raw.startsWith('event:') || raw.startsWith('data:')) raw = raw.split('\n').find(l => l.startsWith('data:')).slice(5);
const result = JSON.parse(raw).result;
if (result.isError) throw new Error(`favicon tool: ${result.content?.[0]?.text}`);
const out = result.structuredContent ?? JSON.parse(result.content[0].text);
const iconSvg = join(tmp, 'icon.svg');
writeFileSync(iconSvg, out.svg);
const iconset = join(tmp, 'AppIcon.iconset');
rmSync(iconset, { recursive: true, force: true });
mkdirSync(iconset);
const master = join(tmp, 'icon-1024.png');
await $`rsvg-convert -w 1024 -h 1024 -o ${master} ${iconSvg}`.quiet();
copyFileSync(master, join(RES, 'AppIcon.png'));
for (const size of [16, 32, 128, 256, 512]) {
  await $`sips -z ${size} ${size} ${master} --out ${join(iconset, `icon_${size}x${size}.png`)}`.quiet();
  await $`sips -z ${size * 2} ${size * 2} ${master} --out ${join(iconset, `icon_${size}x${size}@2x.png`)}`.quiet();
}
await $`iconutil -c icns -o ${join(RES, 'AppIcon.icns')} ${iconset}`.quiet();
console.log(`app icon: S → ${out.link ?? 'ok'}`);

// --- menu bar glyph ------------------------------------------------------------------
// The icon's square in black with the letter cut out (even-odd keeps any counter in ink),
// black on transparent so macOS paints it for light and dark menu bars.
const letter = out.svg.match(/<path[^>]* d="([^"]+)"/)[1];
const glyph = join(tmp, 'menubar.svg');
writeFileSync(glyph, `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 100 100"><path fill="#000000" fill-rule="evenodd" d="M0 0H100V100H0Z ${letter}"/></svg>`);
await $`rsvg-convert -f pdf -o ${join(RES, 'Icons', 'menubar.pdf')} ${glyph}`.quiet();
console.log('menu bar glyph: Icons/menubar.pdf');
