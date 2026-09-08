#!/usr/bin/env node
// Turns a saved Claude Design canvas into the reference PNGs viddik's `viddikDesignParity`
// compares fixtures against: one PNG per static artboard, at the artboard's canvas.json size,
// named after the artboard the way viddik names a golden.
//
//   node canvas-references.mjs --page <saved canvas>.html --out <dir> [--chrome <binary>] [--only <glob>] [--keep]
//   node canvas-references.mjs --dir  <already extracted dir> --out <dir> ...
//
// `--page` is the file the Artifact tool saves when it reads a canvas (or a seeded page); the
// artboards, canvas.json and images are extracted into `<out>/.canvas/` first. `--dir` takes a
// directory the design helper's `--extract` already wrote. Either way every artboard is wrapped
// into a plain HTML document and rendered by headless Chrome (`--chrome`, `$CHROME`, or the usual
// install locations). No dependencies; node 18+.
//
// The output is `<out>/<stem>.png` per artboard plus `<out>/manifest.json`, and a table on stdout.
// Warnings go to stderr and are the part to read: an artboard that carries template logic
// (`{{ holes }}`, `<sc-for>`, `<sc-if>`, `<dc-import>`) does not render standalone — the runtime
// that resolves those is the canvas editor's — and its PNG is not a reference, it is the raw
// template with the braces showing.

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, statSync } from 'node:fs'
import { basename, extname, join, resolve } from 'node:path'

const DATA_ID = '(?: data-id="(?!-)(?:(?!--)[A-Za-z0-9_-]){16}")?'
const DOC_RE = new RegExp('(<script type="application/json" id="appifact-doc"' + DATA_ID + '>\\n)([\\s\\S]*?)(\\n</script>)')
const ARTBOARD_RE = /^[A-Za-z0-9_][A-Za-z0-9 _.-]{0,80}\.dc\.html$/
const IMAGE_EXT = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.avif', '.bmp', '.svg'])
const CANVAS_FILE = 'canvas.json'
const DEFAULT_SIZE = { w: 400, h: 400 }

function fail(msg) { process.stderr.write('canvas-references: ' + msg + '\n'); process.exit(1) }
function warn(msg) { process.stderr.write('canvas-references: warning - ' + msg + '\n') }
function arg(name) { const i = process.argv.lastIndexOf('--' + name); return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : undefined }
function flag(name) { return process.argv.includes('--' + name) }

// --- where the artboards come from ---------------------------------------------------------

function extract(pagePath, to) {
  const page = readFileSync(pagePath, 'utf8').replace(/\r\n/g, '\n')
  const m = page.match(DOC_RE)
  if (!m) fail('no design-canvas state block in ' + pagePath + ' - pass the full saved page (the file the Artifact read names), not a fetch that was cut off')
  let state
  try { state = JSON.parse(m[2]) } catch (e) { fail('the state block in ' + pagePath + ' does not parse: ' + e.message) }
  if (state && state.store === 'db') fail(pagePath + ' keeps its design in a live store this script cannot read; export the artboards from claude.ai/design instead')
  const files = state && state.content && state.content.files
  if (!files || typeof files !== 'object') fail('the state block carries no files')
  mkdirSync(to, { recursive: true })
  const written = []
  for (const [name, value] of Object.entries(files)) {
    if (typeof value !== 'string' || name !== basename(name) || name.includes('..')) continue
    const isImage = IMAGE_EXT.has(extname(name).toLowerCase())
    if (!(ARTBOARD_RE.test(name) || name === CANVAS_FILE || isImage)) continue
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
function standalone(source, w, h) {
  let html = source
    .replace(/<script src="\.\/support\.js"><\/script>\s*/g, '')
    .replace(/<\/?x-dc>/g, '')
    .replace(/<\/?helmet>/g, '')
    .replace(/<script data-dc-script[\s\S]*?<\/script>/g, '')
  const frame = '<style data-canvas-references>html,body{margin:0;padding:0;width:' + w + 'px;height:' + h + 'px;overflow:hidden}</style>'
  html = /<head>/i.test(html) ? html.replace(/<head>/i, '<head>' + frame) : frame + html
  return html
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

function render(chrome, html, png, w, h) {
  execFileSync(chrome, [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars', '--no-first-run', '--disable-extensions',
    '--force-device-scale-factor=1', '--default-background-color=ffffffff',
    '--window-size=' + w + ',' + h, '--virtual-time-budget=5000',
    '--screenshot=' + png, 'file://' + html,
  ], { stdio: ['ignore', 'ignore', 'pipe'], timeout: 60_000 })
}

// --- main ------------------------------------------------------------------------------------

const out = arg('out')
if (!out) fail('--out <dir> is required')
const pagePath = arg('page')
let dir = arg('dir')
if (!pagePath && !dir) fail('pass --page <saved canvas>.html or --dir <extracted dir>')
mkdirSync(out, { recursive: true })

let title = ''
if (pagePath) {
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
const chrome = findChrome()
const rows = []

const boards = readdirSync(dir).filter(n => ARTBOARD_RE.test(n)).sort()
if (boards.length === 0) fail('no .dc.html artboard in ' + dir)
for (const file of boards) {
  const stem = file.slice(0, -'.dc.html'.length)
  if (only && !only.test(stem)) continue
  const entry = layout.get(file)
  const sized = entry && Number.isFinite(entry.w) && Number.isFinite(entry.h)
  const w = sized ? Math.round(entry.w) : DEFAULT_SIZE.w
  const h = sized ? Math.round(entry.h) : DEFAULT_SIZE.h
  const source = readFileSync(join(dir, file), 'utf8')
  const warnings = []
  if (!sized) warnings.push('no size in canvas.json, rendered at ' + w + 'x' + h)
  const logic = logicWarnings(source)
  if (logic.length) warnings.push('not static (' + logic.join(', ') + '); the PNG shows the template, not the design')
  const blobs = blobReferences(source)
  if (blobs) warnings.push(blobs + ' _blob/ image reference(s) - uploaded assets are not in the page and render as broken images')
  const reference = referenceStem(stem)
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
  rows.push({ artboard: file, reference: reference + '.png', width: w, height: h, page: entry && entry.page ? entry.page : null, warnings })
  for (const m of warnings) warn(file + ': ' + m)
}

if (rows.length === 0) fail('--only ' + arg('only') + ' matched none of: ' + boards.join(', '))
writeFileSync(join(out, 'manifest.json'), JSON.stringify({ title, source: pagePath ? resolve(pagePath) : dir, references: rows }, null, 2) + '\n')
const width = Math.max(...rows.map(r => r.reference.length))
process.stdout.write((title ? 'canvas: ' + title + '\n' : '') + rows.map(r => r.reference.padEnd(width) + '  ' + (r.width + 'x' + r.height).padEnd(9) + (r.warnings.length ? 'WARN ' + r.warnings.join('; ') : 'ok')).join('\n') + '\n' + rows.length + ' reference(s) in ' + resolve(out) + '\n')
