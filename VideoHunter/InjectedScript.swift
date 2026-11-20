//
//  InjectedScript.swift
//  VideoHunter
//
//  在 WKWebView 的每一个 frame 里以 documentStart 时机注入。
//  作用：抓取页面里所有可能播放的媒体地址（DOM、网络请求、脚本内容、性能资源）。
//  所有逻辑都包在 try/catch 里，避免影响网页自身运行。
//

import Foundation

enum InjectedScript {
    static let source = #"""
(function () {
  if (window.__vhInstalled) { return; }
  window.__vhInstalled = true;

  var MEDIA_RE = /(\.m3u8|\.m3u|\.mpd|\.mp4|\.m4v|\.mov|\.webm|\.flv|\.ogv|\.mp3|\.m4a)(\?|#|$)/i;
  var SEGMENT_RE = /(\.ts|\.m4s|\.cmfv|\.cmfa|\.aac)(\?|#|$)/i;
  var IMAGE_RE = /(\.jpg|\.jpeg|\.png|\.webp|\.gif|\.avif|\.bmp|\.heic)(\?|#|$)/i;

  var seen = Object.create(null);
  var imageSeen = Object.create(null);
  var imageCount = 0;

  function post(payload) {
    try {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vhMedia;
      if (bridge) { bridge.postMessage(payload); }
    } catch (e) {}
  }

  function postImage(payload) {
    try {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vhImage;
      if (bridge) { bridge.postMessage(payload); }
    } catch (e) {}
  }

  function imageContext(node) {
    try {
      var parts = [];
      if (node) {
        if (node.className && typeof node.className === 'string') { parts.push(node.className); }
        if (node.id) { parts.push(node.id); }
        var parent = node.parentElement;
        if (parent) {
          if (parent.className && typeof parent.className === 'string') { parts.push(parent.className); }
          if (parent.id) { parts.push(parent.id); }
        }
        var figure = node.closest ? node.closest('figure, a, picture') : null;
        if (figure && figure.className && typeof figure.className === 'string') { parts.push(figure.className); }
      }
      return parts.join(' ').slice(0, 160);
    } catch (e) { return ''; }
  }

  function parseSrcset(value) {
    try {
      var best = '';
      var bestScore = -1;
      var parts = String(value || '').split(',');
      for (var i = 0; i < parts.length; i++) {
        var piece = parts[i].trim();
        if (!piece) { continue; }
        var fields = piece.split(/\s+/);
        var candidate = fields[0];
        if (!candidate) { continue; }
        var score = 1;
        if (fields[1]) {
          var token = fields[1].toLowerCase();
          var number = parseFloat(token) || 1;
          if (token.charAt(token.length - 1) === 'w') { score = number; }
          else if (token.charAt(token.length - 1) === 'x') { score = number * 1000; }
        }
        if (score > bestScore) { bestScore = score; best = candidate; }
      }
      return best;
    } catch (e) { return ''; }
  }

  function bestImageSource(node) {
    try {
      if (!node) { return ''; }
      var setValue = '';
      if (node.getAttribute) {
        setValue = node.getAttribute('srcset') || node.getAttribute('data-srcset') || '';
      }
      var fromSet = parseSrcset(setValue);
      if (fromSet) { return fromSet; }
      var src = node.currentSrc || node.src || '';
      if (!src && node.getAttribute) {
        var attrs = ['data-src', 'data-original', 'data-lazy-src', 'data-url', 'data-image', 'data-big', 'data-original-src'];
        for (var i = 0; i < attrs.length; i++) {
          var value = node.getAttribute(attrs[i]);
          if (value) { src = value; break; }
        }
      }
      return src || '';
    } catch (e) { return ''; }
  }

  function pushImage(raw, node, via, alt, width, height, context) {
    try {
      var abs = absolute(raw);
      if (!abs || !/^https?:/i.test(abs)) { return; }
      if (imageSeen[abs] || imageCount >= 400) { return; }
      imageSeen[abs] = true;
      imageCount++;

      var w = Number(width) || 0;
      var h = Number(height) || 0;
      try {
        if (!w && node && node.naturalWidth) { w = node.naturalWidth; }
        if (!h && node && node.naturalHeight) { h = node.naturalHeight; }
      } catch (e) {}

      postImage({
        url: abs,
        width: Math.max(0, Math.round(w)),
        height: Math.max(0, Math.round(h)),
        alt: String(alt || '').slice(0, 160),
        title: (document.title || '').slice(0, 120),
        frame: String(location.href || '').slice(0, 500),
        via: via || 'img',
        context: context || imageContext(node)
      });
    } catch (e) {}
  }

  function scanImages() {
    try {
      var metas = document.querySelectorAll('meta[property="og:image"], meta[name="og:image"], meta[name="twitter:image"], meta[property="twitter:image"]');
      for (var m = 0; m < metas.length && m < 6; m++) {
        var content = metas[m].getAttribute('content') || '';
        if (content) { pushImage(content, null, 'meta', document.title, 0, 0, 'meta og:image'); }
      }
    } catch (e) {}

    try {
      var scripts = document.querySelectorAll('script[type="application/ld+json"]');
      for (var j = 0; j < scripts.length && j < 4; j++) {
        var text = (scripts[j].textContent || '').replace(/\\\//g, '/');
        if (text.indexOf('image') < 0 && text.indexOf('thumbnailUrl') < 0) { continue; }
        var pattern = /"(?:image|thumbnailUrl|contentUrl)"\s*:\s*"([^"]+)"/g;
        var hit = null;
        var guard = 0;
        while ((hit = pattern.exec(text)) !== null && guard < 6) {
          guard++;
          if (hit[1]) { pushImage(hit[1], null, 'jsonld', document.title, 0, 0, 'json-ld'); }
        }
      }
    } catch (e) {}

    try {
      var images = document.querySelectorAll('img');
      var limit = Math.min(images.length, 240);
      for (var i = 0; i < limit; i++) {
        var node = images[i];
        var src = bestImageSource(node);
        if (!src) { continue; }
        if (/^(data|blob):/i.test(src)) { continue; }
        var alt = '';
        try { alt = node.alt || node.getAttribute('data-alt') || node.title || ''; } catch (e) {}
        var w = 0;
        var h = 0;
        try { w = node.naturalWidth || node.width || 0; h = node.naturalHeight || node.height || 0; } catch (e) {}
        if (w > 0 && w <= 2 && h > 0 && h <= 2) { continue; }
        pushImage(src, node, 'img', alt, w, h, imageContext(node));
      }
    } catch (e) {}

    try {
      var sources = document.querySelectorAll('picture source');
      for (var p = 0; p < sources.length && p < 80; p++) {
        var set = sources[p].getAttribute('srcset') || sources[p].getAttribute('data-srcset') || '';
        var best = parseSrcset(set);
        if (best) { pushImage(best, null, 'srcset', '', 0, 0, 'picture'); }
      }
    } catch (e) {}

    try {
      var videos = document.querySelectorAll('video[poster], video[data-poster], video[data-cover]');
      for (var v = 0; v < videos.length && v < 80; v++) {
        var poster = videos[v].poster || videos[v].getAttribute('poster') || videos[v].getAttribute('data-poster') || videos[v].getAttribute('data-cover') || '';
        if (poster) { pushImage(poster, null, 'poster', '视频封面', 0, 0, 'video poster'); }
      }
    } catch (e) {}

    try {
      var anchors = document.querySelectorAll('a[href]');
      for (var a = 0; a < anchors.length && a < 120; a++) {
        var href = '';
        try { href = anchors[a].href || ''; } catch (e) { href = ''; }
        if (!href || !/^https?:/i.test(href)) { continue; }
        if (IMAGE_RE.test(href)) { pushImage(href, anchors[a], 'anchor', '', 0, 0, imageContext(anchors[a])); }
      }
    } catch (e) {}

    try {
      var styled = document.querySelectorAll('[style*="background"]');
      var scanLimit = Math.min(styled.length, 80);
      for (var b = 0; b < scanLimit; b++) {
        var style = styled[b].getAttribute('style') || '';
        var match = style.match(/url\(["']?([^"')]+)["']?\)/);
        if (match && match[1] && !/^(data|blob):/i.test(match[1])) {
          pushImage(match[1], styled[b], 'css', '', 0, 0, imageContext(styled[b]));
        }
      }
    } catch (e) {}
  }

  function absolute(raw) {
    try {
      if (!raw) { return null; }
      var text = String(raw).trim();
      if (!text) { return null; }
      if (/^(javascript|mailto|tel|about):/i.test(text)) { return null; }
      return new URL(text, document.baseURI || location.href).href;
    } catch (e) {
      return null;
    }
  }

  function guessKind(url, contentType) {
    var u = (url || '').toLowerCase();
    var t = (contentType || '').toLowerCase();
    if (u.indexOf('.m3u8') >= 0 || u.indexOf('.m3u') >= 0 || t.indexOf('mpegurl') >= 0) { return 'hls'; }
    if (u.indexOf('.mpd') >= 0 || t.indexOf('dash+xml') >= 0) { return 'dash'; }
    if (u.indexOf('.webm') >= 0 || t.indexOf('webm') >= 0) { return 'webm'; }
    if (u.indexOf('.mp4') >= 0 || u.indexOf('.m4v') >= 0 || u.indexOf('.mov') >= 0 ||
        t.indexOf('video/mp4') >= 0 || t.indexOf('quicktime') >= 0) { return 'mp4'; }
    if (t.indexOf('video/') === 0) { return 'mp4'; }
    return 'other';
  }

  // 有些站点的 HLS 分片是 .mp4 命名的，这里做一层启发式过滤，避免列表被几百个分片刷屏。
  function looksLikeSegment(url) {
    var u = url.toLowerCase();
    if (SEGMENT_RE.test(u)) { return true; }
    if (/(init|seg|segment|chunk|frag|part|slice)[-_]?\d*\.(mp4|m4v|mov)/.test(u)) { return true; }
    if (/\/\d{4,}\.(mp4|m4v|mov)(\?|#|$)/.test(u)) { return true; }
    return false;
  }

  // 页面封面：og:image / twitter:image / JSON-LD 里的图，拿来做没有 poster 的视频预览图。
  var pageImageCache = null;

  function pageImage() {
    if (pageImageCache) { return pageImageCache; }
    try {
      var meta = document.querySelector('meta[property="og:image"], meta[name="og:image"], meta[name="twitter:image"], meta[property="twitter:image"]');
      if (meta) {
        var content = meta.getAttribute('content') || '';
        if (content) {
          pageImageCache = absolute(content) || '';
        }
      }
    } catch (e) {}
    if (!pageImageCache) {
      try {
        var blocks = document.querySelectorAll('script[type="application/ld+json"]');
        for (var i = 0; i < blocks.length && i < 4; i++) {
          var text = (blocks[i].textContent || '').replace(/\\\//g, '/');
          if (text.indexOf('thumbnailUrl') < 0 && text.indexOf('"image"') < 0) { continue; }
          var match = text.match(/"thumbnailUrl"\s*:\s*"([^"]+)"|"image"\s*:\s*"([^"]+)"/);
          if (match) {
            pageImageCache = absolute(match[1] || match[2]) || '';
            break;
          }
        }
      } catch (e) {}
    }
    return pageImageCache || '';
  }

  function report(rawUrl, kind, via, strict, thumb) {
    try {
      var abs = absolute(rawUrl);
      if (!abs) { return; }
      if (SEGMENT_RE.test(abs)) { return; }
      if (strict && looksLikeSegment(abs)) { return; }
      var image = thumb ? (absolute(thumb) || '') : pageImage();
      if (seen[abs]) {
        if (image && !seen[abs].thumb) {
          seen[abs].thumb = image;
          post({
            url: abs,
            kind: kind || guessKind(abs, ''),
            via: via || 'dom',
            title: (document.title || '').slice(0, 120),
            frame: String(location.href || '').slice(0, 500),
            thumb: image
          });
        }
        return;
      }
      seen[abs] = { thumb: image || '' };
      post({
        url: abs,
        kind: kind || guessKind(abs, ''),
        via: via || 'dom',
        title: (document.title || '').slice(0, 120),
        frame: String(location.href || '').slice(0, 500),
        thumb: image || ''
      });
    } catch (e) {}
  }

  /* ---------- 1. 钩住 XMLHttpRequest ---------- */
  try {
    var origOpen = XMLHttpRequest.prototype.open;
    var origSend = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function (method, url) {
      try { this.__vhUrl = url; } catch (e) {}
      return origOpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      try {
        xhr.addEventListener('load', function () {
          try {
            var contentType = '';
            try { contentType = xhr.getResponseHeader('content-type') || ''; } catch (e2) {}
            var responseURL = xhr.responseURL || xhr.__vhUrl || '';
            if (!responseURL) { return; }
            if (MEDIA_RE.test(responseURL) ||
                /mpegurl|video\/|audio\//i.test(contentType) ||
                /dash\+xml/i.test(contentType)) {
              report(responseURL, guessKind(responseURL, contentType), 'xhr', true);
            }
          } catch (e2) {}
        }, false);
      } catch (e2) {}
      return origSend.apply(this, arguments);
    };
  } catch (e) {}

  /* ---------- 2. 钩住 fetch ---------- */
  try {
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function () {
        var args = arguments;
        var input = args[0];
        var requestURL = '';
        try {
          if (typeof input === 'string') { requestURL = input; }
          else if (input && input.url) { requestURL = input.url; }
        } catch (e) {}

        var promise = origFetch.apply(this, args);

        try {
          promise.then(function (response) {
            try {
              if (!response) { return; }
              var contentType = '';
              try { contentType = response.headers.get('content-type') || ''; } catch (e2) {}
              var responseURL = response.url || requestURL || '';
              if (!responseURL) { return; }
              if (MEDIA_RE.test(responseURL) ||
                  /mpegurl|video\/|audio\//i.test(contentType) ||
                  /dash\+xml/i.test(contentType)) {
                report(responseURL, guessKind(responseURL, contentType), 'fetch', true);
              }
            } catch (e2) {}
          }).catch(function () {});
        } catch (e2) {}

        return promise;
      };
    }
  } catch (e) {}

  /* ---------- 3. 钩住 <video>/<source> 的 src 赋值 ---------- */
  function hookSrc(proto) {
    try {
      if (!proto) { return; }
      var descriptor = Object.getOwnPropertyDescriptor(proto, 'src');
      if (!descriptor || !descriptor.get || !descriptor.set) { return; }
      Object.defineProperty(proto, 'src', {
        configurable: true,
        enumerable: descriptor.enumerable,
        get: function () {
          return descriptor.get.call(this);
        },
        set: function (value) {
          try {
            if (value) { report(value, '', 'src', false, (this && this.poster) || ''); }
          } catch (e2) {}
          return descriptor.set.call(this, value);
        }
      });
    } catch (e) {}
  }

  try { hookSrc(window.HTMLMediaElement && HTMLMediaElement.prototype); } catch (e) {}
  try { hookSrc(window.HTMLSourceElement && HTMLSourceElement.prototype); } catch (e) {}

  /* ---------- 4. 扫描 DOM ---------- */
  function scanDom() {
    try {
      var nodes = document.querySelectorAll('video, audio, source');
      if (!nodes || nodes.length === 0) { return; }
      var attrs = ['src', 'data-src', 'data-video', 'data-video-src', 'data-url', 'data-mp4', 'data-m3u8'];

      for (var i = 0; i < nodes.length; i++) {
        var element = nodes[i];
        var tag = element.tagName;
        var candidates = [];
        var poster = '';
        try {
          poster = element.poster || element.getAttribute('poster') || element.getAttribute('data-poster') || element.getAttribute('data-cover') || '';
        } catch (e) {}
        try { if (element.currentSrc) { candidates.push(element.currentSrc); } } catch (e) {}
        try { if (element.src) { candidates.push(element.src); } } catch (e) {}
        for (var a = 0; a < attrs.length; a++) {
          var attrValue = null;
          try { attrValue = element.getAttribute(attrs[a]); } catch (e) {}
          if (attrValue) { candidates.push(attrValue); }
        }
        for (var c = 0; c < candidates.length; c++) {
          if (candidates[c]) {
            report(candidates[c], guessKind(candidates[c], ''), 'dom', false, poster);
          }
        }
      }
    } catch (e) {}
  }

  /* ---------- 5. 扫描内联脚本里的直链 ---------- */
  function scanScripts() {
    try {
      var scripts = document.querySelectorAll('script:not([src])');
      var limit = Math.min(scripts.length, 60);
      for (var i = 0; i < limit; i++) {
        var text = scripts[i].textContent || '';
        if (!text || text.length > 600000) { continue; }
        if (text.indexOf('m3u8') < 0 && text.indexOf('.mp4') < 0 && text.indexOf('.mpd') < 0) { continue; }
        text = text.replace(/\\\//g, '/').replace(/\\u002[fF]/g, '/');
        var pattern = /https?:\/\/[^\s"'<>\\]+?(?:\.m3u8|\.m3u|\.mpd|\.mp4)(?:[^\s"'<>\\]*)?/gi;
        var match = null;
        var guard = 0;
        while ((match = pattern.exec(text)) !== null && guard < 25) {
          guard++;
          report(match[0], '', 'script', false);
        }
      }
    } catch (e) {}
  }

  /* ---------- 6. 扫描 Performance 资源记录 ---------- */
  function scanPerformance() {
    try {
      if (!window.performance || !performance.getEntriesByType) { return; }
      var entries = performance.getEntriesByType('resource');
      for (var i = 0; i < entries.length; i++) {
        var name = entries[i] && entries[i].name;
        if (!name) { continue; }
        if (MEDIA_RE.test(name)) { report(name, '', 'network', true); }
      }
    } catch (e) {}
  }

  /* ---------- 7. 调度 ---------- */
  var scanTimer = null;

  function scheduleScan() {
    if (scanTimer) { return; }
    scanTimer = setTimeout(function () {
      scanTimer = null;
      scanDom();
      scanImages();
      scanPerformance();
    }, 400);
  }

  function fullScan() {
    scanDom();
    scanImages();
    scanPerformance();
  }

  function boot() {
    fullScan();
    scanScripts();
    setTimeout(function () { fullScan(); scanScripts(); }, 1200);
    setTimeout(function () { fullScan(); }, 4000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }

  try {
    var observer = new MutationObserver(scheduleScan);
    observer.observe(document.documentElement || document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src', 'data-src', 'data-video', 'data-url']
    });
  } catch (e) {}

  setInterval(function () {
    if (document.hidden) { return; }
    fullScan();
  }, 3000);

  window.__vhRescan = function () {
    try { scanScripts(); fullScan(); } catch (e) {}
    return true;
  };

  /* ---------- 8. 整站扫描时取页面链接 ---------- */
  function nearestImage(node) {
    try {
      if (!node) { return ''; }
      var inner = node.querySelector ? node.querySelector('img') : null;
      if (inner) {
        var src = bestImageSource(inner);
        if (src) { return src; }
      }
      var parent = node.parentElement;
      for (var depth = 0; parent && depth < 2; depth++) {
        var images = parent.querySelectorAll('img');
        if (images.length > 0) {
          var first = images[0];
          var url = bestImageSource(first);
          if (url) { return url; }
        }
        parent = parent.parentElement;
      }
    } catch (e) {}
    return '';
  }

  window.__vhCollectLinks = function (maxLinks) {
    var result = {
      links: [],
      media: [],
      title: (document.title || '').slice(0, 160),
      url: String(location.href || '')
    };
    try {
      var limit = (typeof maxLinks === 'number' && maxLinks > 0) ? maxLinks : 60;
      var anchors = document.querySelectorAll('a[href]');
      for (var i = 0; i < anchors.length && result.links.length < limit * 3; i++) {
        var href = '';
        try { href = anchors[i].href || ''; } catch (e) { href = ''; }
        if (!href || !/^https?:/i.test(href)) { continue; }
        if (MEDIA_RE.test(href) && !SEGMENT_RE.test(href) && !looksLikeSegment(href)) {
          if (result.media.length < 80) {
            result.media.push({ url: href, kind: guessKind(href, ''), thumb: nearestImage(anchors[i]) });
          }
          continue;
        }
        result.links.push(href);
      }
    } catch (e) {}
    return JSON.stringify(result);
  };
})();
"""#
}
