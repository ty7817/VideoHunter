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

  var seen = Object.create(null);

  function post(payload) {
    try {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vhMedia;
      if (bridge) { bridge.postMessage(payload); }
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

  function report(rawUrl, kind, via, strict) {
    try {
      var abs = absolute(rawUrl);
      if (!abs) { return; }
      if (SEGMENT_RE.test(abs)) { return; }
      if (strict && looksLikeSegment(abs)) { return; }
      if (seen[abs]) { return; }
      seen[abs] = true;
      post({
        url: abs,
        kind: kind || guessKind(abs, ''),
        via: via || 'dom',
        title: (document.title || '').slice(0, 120),
        frame: String(location.href || '').slice(0, 500)
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
            if (value) { report(value, '', 'src'); }
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
        try { if (element.currentSrc) { candidates.push(element.currentSrc); } } catch (e) {}
        try { if (element.src) { candidates.push(element.src); } } catch (e) {}
        for (var a = 0; a < attrs.length; a++) {
          var attrValue = null;
          try { attrValue = element.getAttribute(attrs[a]); } catch (e) {}
          if (attrValue) { candidates.push(attrValue); }
        }
        for (var c = 0; c < candidates.length; c++) {
          if (candidates[c]) {
            report(candidates[c], guessKind(candidates[c], ''), 'dom', false);
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
      scanPerformance();
    }, 400);
  }

  function fullScan() {
    scanDom();
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
})();
"""#
}
