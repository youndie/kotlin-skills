#!/usr/bin/env node
// Turns a Claude Design canvas into the reference PNGs viddik's `viddikDesignParity` compares
// fixtures against: one PNG per static artboard (or per frame inside a single-file canvas), at the
// artboard's canvas.json size (or the frame's own), named the way viddik names a golden.
//
//   node canvas-references.mjs --page <saved canvas>.html --out <dir> [--chrome <binary>] [--only <glob>] [--keep]
//   node canvas-references.mjs --dir  <artboard dir> --out <dir> ...
//   node canvas-references.mjs --dir  <artboard dir> --list-frames
//   node canvas-references.mjs --dir  <artboard dir> --out <dir> --frame 2a=Kiosk_2a_Welcome --frame 2b=Kiosk_2b_Menu_grid
//
// `--page` is the file the Artifact tool saves when it reads a canvas published from Claude Code
// (or a seeded page); the artboards, canvas.json and images are extracted into `<out>/.canvas/`
// first. `--dir` takes a directory of `.dc.html` files: one the design helper's `--extract`
// wrote, or an export from claude.ai/design. Either way every artboard is wrapped into a plain
// HTML document and rendered by headless Chrome (`--chrome`, `$CHROME`, or the usual install
// locations). No dependencies; node 18+.
//
// A canvas exported from claude.ai/design is often ONE file holding several screens - fixed-size
// frames laid out on a page with captions around them - rather than one artboard per screen.
// `--list-frames` finds those frames (the outermost elements with an inline pixel width and
// height) and prints their id and size; `--frame <id or index>=<Name>` renders one of them alone,
// clipped to its content box, as `<Name>.png`. Nothing in the artboard source is edited: the
// wrapper only repositions the frame for the screenshot.
//
// The output is `<out>/<stem>.png` per artboard or frame plus `<out>/manifest.json`, and a table
// on stdout. Warnings go to stderr and are the part to read: template logic (`{{ holes }}`,
// `<sc-for>`, `<sc-if>`, `<dc-import>`) is not resolved here - the runtime that would resolve it
// is either the canvas editor's or the export's own `support.js`, which fetches React from a CDN
// and shows one default state - so such a PNG is the raw template with the braces showing, not
// a reference.

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { basename, extname, join, resolve } from 'node:path'

const DATA_ID = '(?: data-id="(?!-)(?:(?!--)[A-Za-z0-9_-]){16}")?'
const DOC_RE = new RegExp('(<script type="application/json" id="appifact-doc"' + DATA_ID + '>\\n)([\\s\\S]*?)(\\n</script>)')
// The design helper's own artboard grammar, applied to what a published page carries. A directory
// is trusted as it is: an export from claude.ai/design may carry any name, Cyrillic included.
const PUBLISHED_ARTBOARD_RE = /^[A-Za-z0-9_][A-Za-z0-9 _.-]{0,80}\.dc\.html$/
const IMAGE_EXT = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.avif', '.bmp', '.svg'])
const CANVAS_FILE = 'canvas.json'
const DEFAULT_SIZE = { w: 400, h: 400 }
const FRAMES_MARKER = 'canvas-references-frames'

function fail(msg) { process.stderr.write('canvas-references: ' + msg + '\n'); process.exit(1) }
function warn(msg) { process.stderr.write('canvas-references: warning - ' + msg + '\n') }
function arg(name) { const i = process.argv.lastIndexOf('--' + name); return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : undefined }
function args(name) { const out = []; process.argv.forEach((a, i) => { if (a === '--' + name && i + 1 < process.argv.length) out.push(process.argv[i + 1]) }); return out }
function flag(name) { return process.argv.includes('--' + name) }

// --- where the artboards come from ---------------------------------------------------------

function extract(pagePath, to) {
  const page = readFileSync(pagePath, 'utf8').replace(/\r\n/g, '\n')
  const m = page.match(DOC_RE)
  if (!m) fail('no design-canvas state block in ' + pagePath + ' - pass the full saved page (the file the Artifact read names), not a fetch that was cut off')
  let state
  try { state = JSON.parse(m[2]) } catch (e) { fail('the state block in ' + pagePath + ' does not parse: ' + e.message) }
  if (state && state.store === 'db') fail(pagePath + ' keeps its design in a live store this script cannot read; export the artboards from claude.ai/design as files and pass them with --dir')
  const files = state && state.content && state.content.files
  if (!files || typeof files !== 'object') fail('the state block carries no files')
  mkdirSync(to, { recursive: true })
  const written = []
  for (const [name, value] of Object.entries(files)) {
    if (typeof value !== 'string' || name !== basename(name) || name.includes('..')) continue
    const isImage = IMAGE_EXT.has(extname(name).toLowerCase())
    if (!(PUBLISHED_ARTBOARD_RE.test(name) || name === CANVAS_FILE || isImage)) continue
    writeFileSync(join(to, name), isImage ? Buffer.from(value, 'base64') : value)
    written.push(name)
  }
  return { title: String(state.title || ''), written }
}

// --- what an artboard is ---------------------------------------------------------------------

function readCanvas(dir) {
  const path = join(dir, CANVAS_FILE)
  if (!existsSync(path)) return { artboards: [] }
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch (e) { warn('canvas.json does not parse (' + e.message + '); every artboard falls back to ' + DEFAULT_SIZE.w + 'x' + DEFAULT_SIZE.h); return { artboards: [] } }
}

/** viddik's `fileNameFor`: everything outside [A-Za-z0-9_.-] becomes "_". */
function referenceStem(stem) { return stem.replace(/[^A-Za-z0-9_.-]/g, '_') }
function meaningless(stem) { return !/[A-Za-z0-9]/.test(stem) }

function globToRegex(pattern) {
  return new RegExp('^' + pattern.split('').map(c => c === '*' ? '.*' : c === '?' ? '.' : c.replace(/[.+^${}()|[\]\\]/g, '\\$&')).join('') + '$', 'i')
}

/** The template features the editor's runtime resolves and a plain browser does not. */
function logicWarnings(source) {
  const out = []
  if (/\{\{[\s\S]*?\}\}/.test(source)) out.push('{{ holes }}')
  if (/<sc-(for|if)\b/.test(source)) out.push('<sc-for>/<sc-if>')
  if (/<dc-import\b/.test(source)) out.push('<dc-import>')
  return out
}

/** An image uploaded to the canvas as an asset lives outside the page; standalone it is a broken image. */
function blobReferences(source) { return (source.match(/_blob\/[A-Za-z0-9_-]+/g) || []).length }

/** A `.dc.html` as a document a browser renders on its own: runtime hook, wrappers and logic removed. */
function standalone(source, w, h, tail = '') {
  let html = source
    .replace(/<script src="\.\/support\.js"><\/script>\s*/g, '')
    .replace(/<\/?x-dc>/g, '')
    .replace(/<\/?helmet>/g, '')
    .replace(/<script data-dc-script[\s\S]*?<\/script>/g, '')
    .replace(/<script type="text\/x-dc"[\s\S]*?<\/script>/g, '')
  const frame = '<style data-canvas-references>html,body{margin:0;padding:0;width:' + w + 'px;height:' + h + 'px;overflow:hidden}</style>'
  html = /<head>/i.test(html) ? html.replace(/<head>/i, '<head>' + frame) : frame + html
  if (tail) html = /<\/body>/i.test(html) ? html.replace(/<\/body>/i, tail + '</body>') : html + tail
  return html
}

// Runs inside the page. Frames are the outermost elements with an inline pixel width AND height
// of a screen's order of magnitude; their handle is their own id or the nearest ancestor's, else
// their index. The content box is what the fixture renders, so borders are measured and excluded.
const FRAME_JS = `
(function(){
  var all = Array.prototype.slice.call(document.body.querySelectorAll('*'));
  var boxes = all.filter(function(el){ var s = el.style; return /px$/.test(s.width) && /px$/.test(s.height) && parseFloat(s.width) >= 120 && parseFloat(s.height) >= 120; });
  var outer = boxes.filter(function(el){ return !boxes.some(function(o){ return o !== el && o.contains(el); }); });
  function handle(el, i){ var n = el; while (n && n !== document.body) { if (n.id) return n.id; n = n.parentElement; } return String(i); }
  var frames = outer.map(function(el, i){
    var cs = getComputedStyle(el); var r = el.getBoundingClientRect();
    var bl = parseFloat(cs.borderLeftWidth) || 0, bt = parseFloat(cs.borderTopWidth) || 0, br = parseFloat(cs.borderRightWidth) || 0, bb = parseFloat(cs.borderBottomWidth) || 0;
    return { index: i, id: handle(el, i), width: Math.round(r.width - bl - br), height: Math.round(r.height - bt - bb), border: [bt, br, bb, bl],
      logic: /\\{\\{[\\s\\S]*?\\}\\}|<sc-(for|if)\\b|<dc-import\\b/.test(el.outerHTML), imageSlots: el.querySelectorAll('image-slot').length, el: el };
  });
  window.__frames = frames;
  return frames;
})()`

const LIST_JS = '<script>' + FRAME_JS.replace('return frames;', "var s = document.createElement('script'); s.type = 'application/json'; s.id = '" + FRAMES_MARKER + "'; s.textContent = JSON.stringify(frames.map(function(f){ var c = Object.assign({}, f); delete c.el; return c; })); document.body.appendChild(s); return frames;") + '</script>'

function isolateJs(target) {
  return '<script>' + FRAME_JS + `;
(function(){
  var frames = window.__frames; var t = ${JSON.stringify(target)};
  var f = frames.find(function(x){ return x.id === t; }) || frames[parseInt(t, 10)];
  if (!f) { document.title = 'canvas-references: no frame ' + t; return; }
  var el = f.el;
  for (var n = el.parentElement; n && n !== document.documentElement; n = n.parentElement) { n.style.transform = 'none'; n.style.filter = 'none'; n.style.perspective = 'none'; n.style.overflow = 'visible'; }
  Array.prototype.forEach.call(document.body.children, function(c){ if (!c.contains(el)) c.style.visibility = 'hidden'; });
  el.style.position = 'fixed'; el.style.top = (-f.border[0]) + 'px'; el.style.left = (-f.border[3]) + 'px'; el.style.margin = '0'; el.style.zIndex = '2147483647'; el.style.visibility = 'visible';
  document.documentElement.style.overflow = 'hidden'; document.body.style.margin = '0';
})()</script>`
}

// --- the browser -----------------------------------------------------------------------------

function findChrome() {
  const named = arg('chrome') || process.env.CHROME
  if (named) { if (!existsSync(named)) fail('--chrome ' + named + ' does not exist'); return named }
  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    'google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser', 'chrome',
  ]
  for (const c of candidates) {
    if (c.startsWith('/')) { if (existsSync(c)) return c; continue }
    try { execFileSync(c, ['--version'], { stdio: 'ignore' }); return c } catch { /* next */ }
  }
  fail('no Chrome or Chromium found; pass --chrome <binary> or set CHROME')
}

function pngSize(file) {
  const b = readFileSync(file)
  if (b.length < 24 || b.readUInt32BE(12) !== 0x49484452) return null // "IHDR"
  return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) }
}

const CHROME_FLAGS = ['--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars', '--no-first-run', '--disable-extensions',
  '--force-device-scale-factor=1', '--default-background-color=ffffffff', '--virtual-time-budget=5000']

function render(chrome, html, png, w, h) {
  execFileSync(chrome, [...CHROME_FLAGS, '--window-size=' + w + ',' + h, '--screenshot=' + png, 'file://' + html],
    { stdio: ['ignore', 'ignore', 'pipe'], timeout: 60_000 })
}

function dumpDom(chrome, html) {
  return execFileSync(chrome, [...CHROME_FLAGS, '--window-size=4000,4000', '--dump-dom', 'file://' + html],
    { stdio: ['ignore', 'pipe', 'pipe'], timeout: 60_000, maxBuffer: 64 * 1024 * 1024 }).toString('utf8')
}

function listFrames(chrome, dir, stem, source) {
  const wrapper = join(dir, stem + '.frames.html')
  writeFileSync(wrapper, standalone(source, 4000, 4000, LIST_JS))
  try {
    const dom = dumpDom(chrome, wrapper)
    const m = dom.match(new RegExp('<script type="application/json" id="' + FRAMES_MARKER + '">([\\s\\S]*?)</script>'))
    if (!m) return []
    return JSON.parse(m[1].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'))
  } finally {
    if (!flag('keep')) rmSync(wrapper, { force: true })
  }
}

// --- main ------------------------------------------------------------------------------------

const listOnly = flag('list-frames')
const out = arg('out')
if (!out && !listOnly) fail('--out <dir> is required')
const pagePath = arg('page')
let dir = arg('dir')
if (!pagePath && !dir) fail('pass --page <saved canvas>.html or --dir <artboard dir>')
if (out) mkdirSync(out, { recursive: true })

let title = ''
if (pagePath) {
  if (!out) fail('--page needs --out (the artboards are extracted under it)')
  dir = join(out, '.canvas')
  rmSync(dir, { recursive: true, force: true })
  const extracted = extract(resolve(pagePath), dir)
  title = extracted.title
  if (!extracted.written.some(n => n.endsWith('.dc.html'))) fail('the page carries no artboard')
}
dir = resolve(dir)

const canvas = readCanvas(dir)
const layout = new Map((Array.isArray(canvas.artboards) ? canvas.artboards : []).filter(a => a && typeof a.file === 'string').map(a => [a.file, a]))
const only = arg('only') ? globToRegex(arg('only')) : null
const frameNames = new Map(args('frame').map(spec => {
  const eq = spec.indexOf('=')
  if (eq <= 0) fail('--frame takes <id or index>=<Name>, got ' + spec)
  const name = spec.slice(eq + 1)
  if (referenceStem(name) !== name || meaningless(name)) fail('--frame name "' + name + '" is not a viddik file stem ([A-Za-z0-9_.-])')
  return [spec.slice(0, eq), name]
}))
const chrome = findChrome()
const rows = []

const boards = readdirSync(dir).filter(n => n.endsWith('.dc.html') && !n.endsWith('.render.html')).sort()
if (boards.length === 0) fail('no .dc.html artboard in ' + dir)

for (const file of boards) {
  const stem = file.slice(0, -'.dc.html'.length)
  if (only && !only.test(stem)) continue
  const source = readFileSync(join(dir, file), 'utf8')

  if (listOnly || frameNames.size) {
    const frames = listFrames(chrome, dir, stem, source)
    if (listOnly) {
      process.stdout.write(file + ': ' + (frames.length ? frames.length + ' frame(s)' : 'no fixed-size frame found') + '\n')
      for (const f of frames) {
        process.stdout.write('  ' + String(f.index).padEnd(3) + (f.id + '').padEnd(12) + (f.width + 'x' + f.height).padEnd(11) +
          (f.logic ? 'not static  ' : 'static      ') + (f.imageSlots ? f.imageSlots + ' image-slot(s)' : '') + '\n')
      }
      continue
    }
    for (const [target, name] of frameNames) {
      const f = frames.find(x => x.id === target) || frames[parseInt(target, 10)]
      if (!f) { warn(file + ': no frame "' + target + '" (' + frames.map(x => x.id).join(', ') + ')'); continue }
      const warnings = []
      if (f.logic) warnings.push('frame is not static ({{ holes }}, <sc-for>/<sc-if> or <dc-import>); the PNG shows the template, not the design')
      if (f.imageSlots) warnings.push(f.imageSlots + ' <image-slot> placeholder(s) - empty slots draw editor chrome, a guaranteed diff region')
      const wrapper = join(dir, stem + '.render.html')
      const png = join(out, name + '.png')
      writeFileSync(wrapper, standalone(source, f.width, f.height, isolateJs(f.id)))
      try { render(chrome, wrapper, png, f.width, f.height) } catch (e) { warnings.push('chrome failed: ' + String(e.stderr || e.message).trim().split('\n').pop()) } finally { if (!flag('keep')) rmSync(wrapper, { force: true }) }
      const size = existsSync(png) ? pngSize(png) : null
      if (!size) warnings.push('no PNG written')
      else if (size.w !== f.width || size.h !== f.height) warnings.push('PNG is ' + size.w + 'x' + size.h + ', not ' + f.width + 'x' + f.height)
      rows.push({ artboard: file, frame: f.id, reference: name + '.png', width: f.width, height: f.height, page: null, warnings })
      for (const m of warnings) warn(file + ' frame ' + f.id + ': ' + m)
    }
    continue
  }

  const entry = layout.get(file)
  const sized = entry && Number.isFinite(entry.w) && Number.isFinite(entry.h)
  const w = sized ? Math.round(entry.w) : DEFAULT_SIZE.w
  const h = sized ? Math.round(entry.h) : DEFAULT_SIZE.h
  const warnings = []
  if (!sized) warnings.push('no size in canvas.json, rendered at ' + w + 'x' + h + ' - for a single file holding several screens use --list-frames and --frame')
  const logic = logicWarnings(source)
  if (logic.length) warnings.push('not static (' + logic.join(', ') + '); the PNG shows the template, not the design')
  const blobs = blobReferences(source)
  if (blobs) warnings.push(blobs + ' _blob/ image reference(s) - uploaded assets are not in the page and render as broken images')
  const reference = referenceStem(stem)
  if (meaningless(reference)) { warn(file + ': the name sanitises to "' + reference + '", which no fixture can be called; render its frames with --frame <id>=<Name> instead'); continue }
  if (reference !== stem) warnings.push('stem sanitised to "' + reference + '" - name the fixture so that "<group>_<name>" gives exactly this')

  const wrapper = join(dir, stem + '.render.html')
  const png = join(out, reference + '.png')
  writeFileSync(wrapper, standalone(source, w, h))
  try {
    render(chrome, wrapper, png, w, h)
  } catch (e) {
    warnings.push('chrome failed: ' + String(e.stderr || e.message).trim().split('\n').pop())
  } finally {
    if (!flag('keep')) rmSync(wrapper, { force: true })
  }
  const size = existsSync(png) ? pngSize(png) : null
  if (!size) warnings.push('no PNG written')
  else if (size.w !== w || size.h !== h) warnings.push('PNG is ' + size.w + 'x' + size.h + ', not ' + w + 'x' + h)
  rows.push({ artboard: file, frame: null, reference: reference + '.png', width: w, height: h, page: entry && entry.page ? entry.page : null, warnings })
  for (const m of warnings) warn(file + ': ' + m)
}

if (listOnly) process.exit(0)
if (rows.length === 0) fail(only ? '--only ' + arg('only') + ' matched none of: ' + boards.join(', ') : 'nothing rendered')
writeFileSync(join(out, 'manifest.json'), JSON.stringify({ title, source: pagePath ? resolve(pagePath) : dir, references: rows }, null, 2) + '\n')
const width = Math.max(...rows.map(r => r.reference.length))
process.stdout.write((title ? 'canvas: ' + title + '\n' : '') + rows.map(r => r.reference.padEnd(width) + '  ' + (r.width + 'x' + r.height).padEnd(11) + (r.warnings.length ? 'WARN ' + r.warnings.join('; ') : 'ok')).join('\n') + '\n' + rows.length + ' reference(s) in ' + resolve(out) + '\n')
