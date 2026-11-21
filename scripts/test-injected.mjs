import { readFileSync } from 'node:fs';
import { Script, createContext } from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(join(root, 'VideoHunter', 'InjectedScript.swift'), 'utf8');
const start = source.indexOf('#"""') + 4;
const end = source.indexOf('\n"""#', start);
if (start < 4 || end < 0) throw new Error('InjectedScript raw string not found');
const js = source.slice(start, end);

const media = [];
const images = [];
const routes = [];
const timers = [];
let timerId = 0;
let href = 'https://example.com/start';

const video = {
  tagName: 'VIDEO',
  currentSrc: '',
  src: 'https://cdn.example.com/movie.mp4',
  poster: '',
  naturalWidth: 0,
  naturalHeight: 0,
  getAttribute() { return null; },
  closest() { return null; },
  parentElement: null,
};

const document = {
  baseURI: 'https://example.com/start',
  title: '测试页',
  readyState: 'complete',
  hidden: false,
  documentElement: { tagName: 'HTML' },
  querySelector(selector) { return null; },
  querySelectorAll(selector) {
    if (selector === 'video, audio, source') return [video];
    return [];
  },
  addEventListener() {},
};

const windowStub = {
  document,
  location: {
    get href() { return href; },
    set href(value) { href = String(value); },
  },
  top: {},
  performance: { getEntriesByType() { return []; } },
  addEventListener() {},
  setTimeout(fn, ms) {
    const id = ++timerId;
    timers.push({ id, fn, ms });
    return id;
  },
  setInterval() { return 1; },
  clearInterval() {},
  webkit: {
    messageHandlers: {
      vhMedia: { postMessage(payload) { media.push(payload); } },
      vhImage: { postMessage(payload) { images.push(payload); } },
      vhRoute: { postMessage(payload) { routes.push(payload); } },
    },
  },
  __vhBaseGeneration: 0,
};
windowStub.top = windowStub;

const history = {
  pushState(state, title, url) {
    if (url) href = new URL(String(url), href).href;
  },
  replaceState(state, title, url) {
    if (url) href = new URL(String(url), href).href;
  },
};

class MutationObserver {
  observe() {}
  disconnect() {}
}

class XMLHttpRequest {
  open() {}
  send() {}
}

const context = createContext({
  window: windowStub,
  document,
  location: windowStub.location,
  history,
  navigator: { userAgent: 'test' },
  URL,
  MutationObserver,
  XMLHttpRequest,
  console,
  performance: windowStub.performance,
  setTimeout: windowStub.setTimeout,
  setInterval: windowStub.setInterval,
  clearInterval: windowStub.clearInterval,
  JSON,
  Math,
  String,
  Number,
  Object,
  Array,
  RegExp,
  Date,
});
context.globalThis = context;

const flush = () => {
  let guard = 0;
  while (timers.length && guard < 200) {
    guard += 1;
    timers.shift().fn();
  }
};

new Script(js, { filename: 'InjectedScript.js' }).runInContext(context);
flush();

if (media.length === 0) throw new Error('boot scan did not emit media');
if (media[0].generation !== 0) throw new Error('initial generation should be 0');
if (media[0].isIframe !== false) throw new Error('main frame should not be marked as iframe');
console.log(`boot media messages: ${media.length}, generation=${media[0].generation}`);

const beforeRoute = media.length;
history.pushState({}, '', '/spa-route');
flush();

if (routes.length !== 1) throw new Error(`expected 1 route message, got ${routes.length}`);
if (routes[0].generation !== 1) throw new Error('SPA route should increment generation to 1');
if (!String(routes[0].url).includes('/spa-route')) throw new Error('route URL mismatch');
if (media.length <= beforeRoute) throw new Error('route reset should cause the page to be re-scanned');
const newest = media[media.length - 1];
if (newest.generation !== 1) throw new Error('post-route media should carry generation 1');
console.log(`SPA route: generation=${routes[0].generation}, url=${routes[0].url}`);
console.log(`post-route media: generation=${newest.generation}`);

const beforeRescan = media.length;
context.window.__vhRescan();
flush();
if (media.length !== beforeRescan) throw new Error('rescan without route change should still dedupe');
console.log('dedupe before route change: ok');

// 模拟 iframe：重新执行会命中 __vhInstalled；这里只验证 isIframe() 的反向分支靠主文档即可。
const imagePayload = images[0];
if (imagePayload && imagePayload.generation !== 0) throw new Error('image generation mismatch');

console.log('InjectedScript smoke test passed');
