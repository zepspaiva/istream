/*
 * The player: a video link played full screen over the home screen, the TV's own engine underneath (it plays
 * MKV, HEVC, Dolby Vision and switches audio tracks: measured on a 2025 LG, webOS 10).
 *  - Opened by a launch with {url, title, poster, label, start, logUrl, meta} (the Raspberry Pi's "play on the TV";
 *    meta: {show, season, episode, episodeTitle, description, backdrop, logo, year, country}). While the stream
 *    loads, a start screen shows the title (its backdrop, logo, episode); the video fades in over it.
 *    A launch with {cmd: 'audio' | 'pause' | 'play' | 'stop'} controls it; {cmd: 'subs', subsUrl, url} adds
 *    subtitles that came after the video.
 *  - Audio: the original language when the file has it (from the title's country), else English, else the file's
 *    own default. Subtitles: from the add-ons (subsUrl in the launch: the Pi lists and reads them), English by default, the last choice
 *    remembered. ▲ opens the menu: Audio | Subtitles (◀ ▶ switch, ▲ ▼ choose, OK picks).
 *  - Back leaves it: the video stops and its place is kept, for the home screen's "Now playing" (Player.current()).
 *  - OK pauses, ◀ ▶ jump 10 s (presses add up into one jump), ▼ shows or hides the info.
 * ES5, as the rest of web/: older TVs run an old Chromium.
 */
(function () {
  'use strict';

  var SAVE_KEY = 'fmtv.nowPlaying';
  var KEEP_DAYS = 14;
  var STEP = 10;

  var layer = null, v = null, hud = null, titleEl = null, stateEl = null, fill = null, timeEl = null, infoEl = null;
  var intro = null, menu = null, subsEl = null;
  var item = null;            // what's playing: {url, title, poster, label, logUrl, meta}
  var openFlag = false, hudTimer = 0, saveTimer = 0, seekTimer = 0, seekBy = 0, startedAt = 0;
  var menuOpen = false, menuIndex = 0, menuTab = 'subs', audioPicked = false;
  var subIndex = -1, cues = [], cueAt = -1, subLoading = null;
  var pendingLog = [], logUrl = null;
  var closeListeners = [], changeListeners = [];

  /** What's playing changed ('state') or its audio and subtitle choices did ('tracks'): for the phone (channel.js). */
  function changed(kind) {
    for (var i = 0; i < changeListeners.length; i++) {
      try { changeListeners[i](kind); } catch (e) {}
    }
  }

  // tr() and trf() are strings.js's (the app's languages), loaded before this file.

  function el(tag, cls, parent, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    if (parent) parent.appendChild(e);
    return e;
  }

  function fmt(s) {
    if (!isFinite(s) || s < 0) return '--:--';
    s = Math.floor(s);
    var h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60;
    return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (x < 10 ? '0' : '') + x;
  }

  function cssUrl(u) { return 'url("' + String(u).replace(/"/g, '%22') + '")'; }

  // --- languages --------------------------------------------------------------------------------------------------

  // Track languages arrive as codes (en, eng, spa, es-ES): two-letter code -> the language's name (in English).
  var LANGS = {en: 'English', es: 'Spanish', fr: 'French', de: 'German', it: 'Italian', pt: 'Portuguese', ja: 'Japanese',
    ko: 'Korean', zh: 'Chinese', ru: 'Russian', hi: 'Hindi', ca: 'Catalan', pl: 'Polish', nl: 'Dutch', sv: 'Swedish',
    da: 'Danish', no: 'Norwegian', fi: 'Finnish', tr: 'Turkish', ar: 'Arabic', he: 'Hebrew', cs: 'Czech', el: 'Greek',
    hu: 'Hungarian', ro: 'Romanian', uk: 'Ukrainian', th: 'Thai', vi: 'Vietnamese', id: 'Indonesian', eu: 'Basque',
    gl: 'Galician', ta: 'Tamil', te: 'Telugu'};
  var THREE = {eng: 'en', spa: 'es', fre: 'fr', fra: 'fr', ger: 'de', deu: 'de', ita: 'it', por: 'pt', jpn: 'ja', kor: 'ko',
    chi: 'zh', zho: 'zh', rus: 'ru', hin: 'hi', cat: 'ca', pol: 'pl', dut: 'nl', nld: 'nl', swe: 'sv', dan: 'da', nor: 'no',
    nob: 'no', fin: 'fi', tur: 'tr', ara: 'ar', heb: 'he', cze: 'cs', ces: 'cs', gre: 'el', ell: 'el', hun: 'hu', rum: 'ro',
    ron: 'ro', ukr: 'uk', tha: 'th', vie: 'vi', ind: 'id', baq: 'eu', eus: 'eu', glg: 'gl', tam: 'ta', tel: 'te'};
  // The original language from the title's country (its first one): addons give a country, not a language.
  var COUNTRY = {'united states': 'en', 'usa': 'en', 'united kingdom': 'en', 'uk': 'en', 'canada': 'en', 'australia': 'en',
    'ireland': 'en', 'new zealand': 'en', 'spain': 'es', 'mexico': 'es', 'argentina': 'es', 'colombia': 'es', 'chile': 'es',
    'france': 'fr', 'germany': 'de', 'austria': 'de', 'italy': 'it', 'japan': 'ja', 'south korea': 'ko', 'korea': 'ko',
    'china': 'zh', 'taiwan': 'zh', 'hong kong': 'zh', 'brazil': 'pt', 'portugal': 'pt', 'india': 'hi', 'russia': 'ru',
    'denmark': 'da', 'sweden': 'sv', 'norway': 'no', 'finland': 'fi', 'netherlands': 'nl', 'poland': 'pl', 'turkey': 'tr',
    'israel': 'he', 'thailand': 'th', 'iceland': 'is', 'czech republic': 'cs', 'greece': 'el', 'ukraine': 'uk'};

  function langCode(code) {
    var c = String(code || '').toLowerCase().split(/[-_]/)[0];
    return THREE[c] || c;
  }

  function langName(code) {
    var c = langCode(code);
    return LANGS[c] || (c && c !== 'und' ? c.toUpperCase() : tr('Unknown'));
  }

  function originalLanguage() {
    var country = item && item.meta && item.meta.country;
    if (!country) return null;
    return COUNTRY[String(country).split(',')[0].replace(/^\s+|\s+$/g, '').toLowerCase()] || null;
  }

  // --- what the TV reports, sent to the Pi (logUrl) for the record ----------------------------------------------

  function log(msg) {
    pendingLog.push(new Date().toISOString().slice(11, 19) + ' ' + msg);
    if (pendingLog.length > 200) pendingLog.shift();
  }

  setInterval(function () {
    if (!logUrl || !pendingLog.length) return;
    var batch = pendingLog;
    pendingLog = [];
    try {
      var x = new XMLHttpRequest();
      x.open('POST', logUrl, true);
      x.setRequestHeader('Content-Type', 'text/plain');
      x.send(JSON.stringify({lines: batch}));
    } catch (e) {}
  }, 2000);

  // --- the saved place ------------------------------------------------------------------------------------------

  function load() {
    try {
      var s = JSON.parse(localStorage.getItem(SAVE_KEY) || 'null');
      if (s && s.url && Date.now() - (s.at || 0) < KEEP_DAYS * 86400000) return s;
    } catch (e) {}
    return null;
  }

  function save(clear) {
    try {
      if (clear || !item) { localStorage.removeItem(SAVE_KEY); return; }
      var d = v && isFinite(v.duration) ? v.duration : (item.duration || 0);
      var pos = v && v.currentTime ? v.currentTime : (item.position || 0);
      if (d && pos > d * 0.95) { localStorage.removeItem(SAVE_KEY); return; }   // watched
      item.position = pos;
      item.duration = d;
      item.at = Date.now();
      localStorage.setItem(SAVE_KEY, JSON.stringify(item));
    } catch (e) {}
  }

  // --- the layer --------------------------------------------------------------------------------------------------

  function build() {
    if (layer) return;
    layer = el('div', 'layer', document.getElementById('stage') || document.body);
    layer.id = 'player';
    v = el('video', '', layer);
    v.setAttribute('preload', 'auto');
    subsEl = el('div', 'subs', layer);
    intro = el('div', 'intro', layer);
    hud = el('div', 'hud', layer);
    titleEl = el('div', 'title', hud);
    stateEl = el('div', 'state', hud);
    var bar = el('div', 'bar', hud);
    fill = el('div', 'fill', bar);
    timeEl = el('div', 'time', hud);
    infoEl = el('div', 'info', hud);
    menu = el('div', 'menu', layer);

    var events = ['loadedmetadata', 'playing', 'waiting', 'stalled', 'pause', 'ended', 'seeked'];
    for (var i = 0; i < events.length; i++) {
      (function (name) {
        v.addEventListener(name, function () { onEvent(name); });
      })(events[i]);
    }
    v.addEventListener('error', function () {
      var err = v.error, msg = err ? 'code ' + err.code + (err.message ? ': ' + err.message : '') : 'unknown';
      log('ERROR ' + msg);
      setState(trf("Can't play this video ({reason})", {reason: msg}));
      if (introOn()) setIntroState(trf("Can't play this video ({reason})", {reason: msg}));
      else showHud(true);
    });
    v.addEventListener('timeupdate', paintTime);
  }

  /** The start screen: the title over its backdrop while the stream loads (the hero's look). */
  function paintIntro() {
    var meta = item.meta || {};
    intro.innerHTML = '';
    var art = el('div', 'art', intro);
    if (meta.backdrop || item.poster) art.style.backgroundImage = cssUrl(meta.backdrop || item.poster);
    el('div', 'scrim', intro);
    var box = el('div', 'box', intro);
    var name = meta.show || item.title || '';
    if (meta.logo) {
      var logo = el('img', 'logo', box);
      logo.onerror = function () { box.replaceChild(el('div', 'name', null, name), logo); };
      logo.src = meta.logo;
    } else {
      el('div', 'name', box, name);
    }
    var bits = [];
    if (meta.season && meta.episode) bits.push(trf('S{s} · E{e}', {s: meta.season, e: meta.episode}));
    if (meta.episodeTitle) bits.push(meta.episodeTitle);
    else if (meta.year) bits.push(String(meta.year));
    if (bits.length) el('div', 'meta', box, bits.join('  ·  '));
    if (meta.description) el('div', 'desc', box, meta.description);
    var st = el('div', 'state', box);
    el('span', 'spin', st);
    el('span', 'text', st, tr('Loading…'));
    intro.className = 'intro on';
  }

  function introOn() { return intro && intro.className === 'intro on'; }

  function setIntroState(text) {
    var s = intro.querySelector('.state .text');
    if (s) s.textContent = text;
    var spin = intro.querySelector('.spin');
    if (spin) spin.style.display = 'none';
  }

  function onEvent(name) {
    if (name === 'loadedmetadata') {
      log('loadedmetadata ' + v.videoWidth + 'x' + v.videoHeight + ', ' + fmt(v.duration));
      setTimeout(function () { describeTracks(); pickAudio(); changed('tracks'); }, 300);
    } else {
      log(name + ' (t=' + fmt(v.currentTime) + ')');
    }
    if (name === 'playing') {
      if (startedAt) { log('first frame after ' + ((Date.now() - startedAt) / 1000).toFixed(1) + ' s'); startedAt = 0; }
      intro.className = 'intro';
      setState('');
      showHud(false);
    } else if (name === 'waiting' || name === 'stalled') {
      if (!v.paused) setState(tr('Loading…'));
    } else if (name === 'pause') {
      if (v.error || introOn()) return;   // a stream that failed, or hasn't started: the start screen says so
      setState(tr('Paused'));
      showHud(true);
      save();
    } else if (name === 'ended') {
      save(true);
      close();
    }
    changed('state');
  }

  function tracks() {
    var at = v && v.audioTracks, out = [];
    if (!at) return out;
    for (var i = 0; i < at.length; i++) out.push(at[i]);
    return out;
  }

  function describeTracks() {
    var list = tracks(), names = [];
    for (var i = 0; i < list.length; i++) names.push((list[i].language || '?') + (list[i].label ? ' ' + list[i].label : '') + (list[i].enabled ? ' *' : ''));
    log('audioTracks ' + list.length + ' [' + names.join(', ') + '], original: ' + (originalLanguage() || 'unknown'));
    paintInfo();
  }

  /** Once per video: the original language if the file has it, else English, else the file's default. */
  function pickAudio() {
    if (audioPicked) return;
    audioPicked = true;
    var list = tracks();
    if (list.length < 2) return;
    var want = [originalLanguage(), 'en'];
    for (var w = 0; w < want.length; w++) {
      if (!want[w]) continue;
      for (var i = 0; i < list.length; i++) {
        if (langCode(list[i].language) === want[w]) {
          if (!list[i].enabled) setAudio(i);
          log('audio: ' + want[w] + (w === 0 ? ' (original)' : ' (English)'));
          return;
        }
      }
    }
  }

  function setAudio(index) {
    var list = tracks();
    for (var j = 0; j < list.length; j++) list[j].enabled = (j === index);
    log('audio track -> ' + index + ' (' + (list[index] && list[index].language) + ')');
    paintInfo();
    changed('tracks');
  }

  /** "English", "Spanish", or "English 2" when two tracks share a language. */
  function trackNames() {
    var list = tracks(), names = [], seen = {};
    for (var i = 0; i < list.length; i++) {
      var n = langName(list[i].language);
      seen[n] = (seen[n] || 0) + 1;
      names.push(seen[n] > 1 ? n + ' ' + seen[n] : n);
    }
    if (list.length === 1) names[0] = list[0].language ? names[0] : tr('Default');
    return names;
  }

  function audioName() {
    var list = tracks(), names = trackNames();
    if (list.length < 2) return '';
    for (var i = 0; i < list.length; i++) if (list[i].enabled) return trf('Audio: {name}', {name: names[i]});
    return '';
  }

  function paintInfo() {
    var parts = [];
    if (item && item.label) parts.push(item.label);
    var a = audioName();
    if (a) parts.push(a);
    if (subIndex >= 0) parts.push(trf('Subtitles: {name}', {name: subNames()[subIndex] || ''}));
    infoEl.textContent = parts.join('   ·   ');
  }

  function paintTime() {
    if (!v) return;
    var d = v.duration, now = v.currentTime + seekBy;
    if (isFinite(d) && d > 0) fill.style.width = Math.max(0, Math.min(100, 100 * now / d)) + '%';
    timeEl.textContent = fmt(now) + ' / ' + fmt(d) + (seekBy ? '   (' + (seekBy > 0 ? '+' : '−') + Math.abs(seekBy) + ' s)' : '');
  }

  function setState(s) { stateEl.textContent = s; }

  function showHud(sticky) {
    if (introOn()) return;   // the start screen is up: the video (and its bar) come after
    hud.className = 'hud';
    subsEl.className = 'subs raised';
    clearTimeout(hudTimer);
    if (!sticky) hudTimer = setTimeout(function () { if (v && !v.paused && !menuOpen) hideHud(); }, 4000);
  }

  function hideHud() {
    hud.className = 'hud hide';
    subsEl.className = 'subs';
  }

  // --- subtitles -------------------------------------------------------------------------------------------------
  // The add-ons' subtitles, sent with the video ({i, lang, sdh}); the Pi reads each file into timed lines
  // (subsUrl + i: {cues: [{s, e, t}]}), drawn here over the video. English by default; the choice is remembered
  // (a language, or off) for the next video.

  var SUB_PREF = 'fmtv.subtitles';

  function subPref() {
    try { return localStorage.getItem(SUB_PREF) || 'en'; } catch (e) { return 'en'; }
  }

  function setSubPref(value) {
    try { localStorage.setItem(SUB_PREF, value); } catch (e) {}
  }

  /** "English", "English 2", "Spanish (SDH)": one per subtitle offered. */
  function subNames() {
    var list = (item && item.subs) || [], names = [], seen = {};
    for (var i = 0; i < list.length; i++) {
      var n = langName(list[i].lang);
      seen[n] = (seen[n] || 0) + 1;
      names.push((seen[n] > 1 ? n + ' ' + seen[n] : n) + (list[i].sdh ? ' (SDH)' : ''));
    }
    return names;
  }

  /** The preferred language's first subtitle (one without SDH first), or -1. */
  function defaultSub() {
    var want = subPref(), list = (item && item.subs) || [], sdh = -1;
    if (want === 'off') return -1;
    for (var i = 0; i < list.length; i++) {
      if (langCode(list[i].lang) !== want) continue;
      if (!list[i].sdh) return i;
      if (sdh < 0) sdh = i;
    }
    return sdh;
  }

  function showSub(index) {
    subIndex = index;
    cues = [];
    cueAt = -1;
    subsEl.innerHTML = '';
    item.sub = index;
    paintInfo();
    changed('tracks');
    if (index < 0) return;
    var asked = item.url + '#' + index;
    subLoading = asked;
    if (!item.subsUrl) {
      var chosen = item.subs && item.subs[index];
      if (chosen && chosen.url) fetchCues(chosen.url, asked, index);
      return;
    }
    try {
      var x = new XMLHttpRequest();
      x.open('GET', item.subsUrl + index, true);
      x.onload = function () {
        if (subLoading !== asked) return;   // another one was picked meanwhile
        try { cues = JSON.parse(x.responseText).cues || []; } catch (e) { cues = []; }
        log('subtitle ' + index + ': ' + cues.length + ' lines' + (cues.length ? ', until ' + fmt(cues[cues.length - 1].e) : ''));
        if (!cues.length) log('subtitle ' + index + ' came back empty (' + x.status + ')');
      };
      x.onerror = function () { log('subtitle ' + index + ' failed'); };
      x.send();
    } catch (e) {}
  }

  // Subtitles straight from the add-on's address (no Pi): read and turned into timed lines here. When the TV can't
  // read the file (the server doesn't allow it, or it's gzipped), the phone reads it and sends the lines (addCues).

  var phoneAsk = null;   // {url, asked}: the subtitle the phone was asked for

  function fetchCues(url, asked, index) {
    try {
      var x = new XMLHttpRequest();
      x.open('GET', url, true);
      x.responseType = 'arraybuffer';
      x.timeout = 20000;
      x.onload = function () {
        if (subLoading !== asked) return;
        var bytes = x.status >= 200 && x.status < 300 && x.response ? new Uint8Array(x.response) : null;
        if (!bytes || (bytes[0] === 0x1f && bytes[1] === 0x8b)) { askPhone(url, asked); return; }
        cues = parseSubs(decodeText(bytes));
        log('subtitle ' + index + ': ' + cues.length + ' lines (read here)');
        if (!cues.length) askPhone(url, asked);
      };
      x.onerror = x.ontimeout = function () { if (subLoading === asked) askPhone(url, asked); };
      x.send();
    } catch (e) {
      askPhone(url, asked);
    }
  }

  function askPhone(url, asked) {
    phoneAsk = {url: url, asked: asked};
    log('subtitle: asking the phone for ' + url.slice(0, 80));
    if (window.Player.onNeedSubtitle) window.Player.onNeedSubtitle(url);
  }

  /** Lines the phone read for us: the first part replaces, the next ones add. */
  function addCues(url, list, first) {
    if (!phoneAsk || phoneAsk.url !== url || subLoading !== phoneAsk.asked) return;
    cues = first ? list.slice(0) : cues.concat(list);
    cueAt = -1;
  }

  /** UTF-8 when it is, else Windows-1252 (most older subtitles), as the Pi did. */
  function decodeText(bytes) {
    var start = bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf ? 3 : 0;
    var body = bytes.subarray(start);
    if (window.TextDecoder) {
      try { return new window.TextDecoder('utf-8', {fatal: true}).decode(body); } catch (e) {}
      try { return new window.TextDecoder('windows-1252').decode(body); } catch (e2) {}
    }
    var out = '';
    for (var i = 0; i < body.length; i += 8192) {
      out += String.fromCharCode.apply(null, Array.prototype.slice.call(body.subarray(i, i + 8192)));
    }
    return out;
  }

  var CUE_TIME = /(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})/;
  var CUE_TAGS = /<[^>]*>|\{\\[^}]*\}/g;

  function secs(h, m, s, ms) {
    return (Number(h) || 0) * 3600 + Number(m) * 60 + Number(s) + Number((ms + '00').slice(0, 3)) / 1000;
  }

  /** SRT and WebVTT alike: every block with a "start --> end" line; the lines after it are the text. */
  function parseSubs(text) {
    var out = [], blocks = text.replace(/\r\n/g, '\n').split(/\n\s*\n/);
    for (var b = 0; b < blocks.length; b++) {
      var lines = blocks[b].replace(/^\n+|\n+$/g, '').split('\n');
      for (var i = 0; i < lines.length; i++) {
        var m = CUE_TIME.exec(lines[i]);
        if (!m) continue;
        var start = secs(m[1], m[2], m[3], m[4]), end = secs(m[5], m[6], m[7], m[8]), body = [];
        for (var j = i + 1; j < lines.length; j++) body.push(lines[j].replace(CUE_TAGS, '').replace(/^\s+|\s+$/g, ''));
        var t = body.join('\n').replace(/^\s+|\s+$/g, '');
        if (t && end > start) out.push({s: Math.round(start * 1000) / 1000, e: Math.round(end * 1000) / 1000, t: t.slice(0, 400)});
        break;
      }
    }
    out.sort(function (a, c) { return a.s - c.s; });
    return out;
  }

  /** The subtitles' list, read from the Pi (<subsUrl>list): then done(). Kept with what's playing. */
  function loadSubList(done) {
    if (!item || !item.subsUrl) return;
    var forUrl = item.url;
    try {
      var x = new XMLHttpRequest();
      x.open('GET', item.subsUrl + 'list', true);
      x.onload = function () {
        if (!item || item.url !== forUrl) return;
        var list = [];
        try { list = JSON.parse(x.responseText).subs || []; } catch (e) {}
        item.subs = list;
        log('subtitles listed: ' + list.length);
        save();
        done();
      };
      x.onerror = function () { log('subtitle list failed'); };
      x.send();
    } catch (e) {}
  }

  /** The subtitle to show once the list is known: the one picked before (on a resume), else the default. */
  function chooseSub() {
    var keep = item.sub >= 0 && item.sub < item.subs.length;   // a subtitle that was on (not "none yet")
    if (item.subPicked || keep) showSub(keep ? item.sub : -1);
    else showSub(defaultSub());
    if (menuOpen) paintMenu();
  }

  /** The line for the current time (a binary search: the cues are sorted by start). */
  function tickSubs() {
    if (!openFlag || subIndex < 0 || !cues.length) return;
    var now = v.currentTime, lo = 0, hi = cues.length - 1, found = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (cues[mid].s <= now) { found = mid; lo = mid + 1; } else hi = mid - 1;
    }
    // Overlapping lines: the latest one that has started and not ended.
    while (found >= 0 && cues[found].e < now && found > 0 && cues[found - 1].e >= now) found--;
    var show = found >= 0 && cues[found].e >= now ? found : -1;
    if (show === cueAt) return;
    cueAt = show;
    subsEl.innerHTML = '';
    if (show < 0) return;
    var lines = cues[show].t.split('\n');
    for (var i = 0; i < lines.length; i++) el('span', 'line', subsEl, lines[i]);
  }
  setInterval(tickSubs, 120);

  // --- the menu: Audio | Subtitles --------------------------------------------------------------------------------

  function menuRows() {
    if (menuTab === 'subs') {
      var names = subNames(), rows = [{label: tr('Off'), on: subIndex < 0, pick: function () { item.subPicked = true; showSub(-1); setSubPref('off'); }}];
      for (var i = 0; i < names.length; i++) {
        (function (n) {
          rows.push({label: names[n], on: subIndex === n, pick: function () { item.subPicked = true; showSub(n); setSubPref(langCode(item.subs[n].lang)); }});
        })(i);
      }
      return rows;
    }
    var list = tracks(), tnames = trackNames(), out = [];
    if (!list.length) out.push({label: tr('Default'), on: true, pick: function () {}});
    for (var j = 0; j < list.length; j++) {
      (function (n) { out.push({label: tnames[n], on: list[n].enabled, pick: function () { setAudio(n); }}); })(j);
    }
    return out;
  }

  function paintMenu() {
    menu.innerHTML = '';
    var head = el('div', 'tabs', menu);
    el('span', 'tab' + (menuTab === 'audio' ? ' on' : ''), head, tr('Audio'));
    el('span', 'tab' + (menuTab === 'subs' ? ' on' : ''), head, tr('Subtitles'));
    var rows = menuRows();
    for (var i = 0; i < rows.length; i++) {
      var row = el('div', 'row' + (i === menuIndex ? ' focus' : '') + (rows[i].on ? ' on' : ''), menu);
      el('span', 'tick', row, rows[i].on ? '✓' : '');
      el('span', '', row, rows[i].label);
    }
  }

  function focusChosen() {
    var rows = menuRows();
    menuIndex = 0;
    for (var i = 0; i < rows.length; i++) if (rows[i].on) menuIndex = i;
  }

  function openMenu() {
    menuOpen = true;
    focusChosen();
    paintMenu();
    menu.className = 'menu on';
    showHud(true);
  }

  function closeMenu() {
    menuOpen = false;
    menu.className = 'menu';
    showHud(false);
  }

  function menuKey(k) {
    var n = menuRows().length;
    if (k === 38) menuIndex = Math.max(0, menuIndex - 1);
    else if (k === 40) menuIndex = Math.min(n - 1, menuIndex + 1);
    else if (k === 37 || k === 39) { menuTab = menuTab === 'audio' ? 'subs' : 'audio'; focusChosen(); }
    else if (k === 13) { var rows = menuRows(); if (rows[menuIndex]) rows[menuIndex].pick(); closeMenu(); return; }
    else if (k === 461 || k === 10009 || k === 27 || k === 8) { closeMenu(); return; }
    paintMenu();
  }

  // --- opening and closing ----------------------------------------------------------------------------------------

  function open(params) {
    if (!params || !params.url) return;
    build();
    var saved = load(), same = saved && saved.url === params.url;
    var meta = params.meta;
    if (typeof meta === 'string') { try { meta = JSON.parse(meta); } catch (x) { meta = null; } }
    var resumeAt = params.start !== undefined && params.start !== null ? Number(params.start) || 0 : (same ? saved.position || 0 : 0);
    item = {url: params.url, title: params.title || '', poster: params.poster || (same ? saved.poster : '') || '',
            label: params.label || '', logUrl: params.logUrl || (saved && saved.logUrl) || null, position: resumeAt,
            meta: meta || (same ? saved.meta : null) || null,
            subs: params.subs || params.subtitles || (same ? saved.subs : null) || [],
            subsUrl: params.subsUrl || (same ? saved.subsUrl : null) || null,
            sub: same && saved.sub !== undefined ? saved.sub : null, subPicked: !!(same && saved.subPicked)};
    if (typeof item.subs === 'string') { try { item.subs = JSON.parse(item.subs); } catch (x) { item.subs = []; } }
    if (params.subtitles && !params.subsUrl) item.subsUrl = null;   // the phone's list: each has its own address
    // What the phone knows the video as ({type, contentId, videoId}), so it can save the place in the account.
    var session = params.session;
    if (typeof session === 'string') { try { session = JSON.parse(session); } catch (x) { session = null; } }
    item.ref = session && session.videoId ? {type: session.type, contentId: session.contentId, videoId: session.videoId}
      : (params.ref || (same ? saved.ref : null) || null);
    if (item.logUrl) logUrl = item.logUrl;
    log('open "' + item.title + '"' + (item.label ? ' [' + item.label + ']' : '') + (resumeAt ? ' from ' + fmt(resumeAt) : ''));
    var m = item.meta || {};
    titleEl.textContent = m.season && m.episode ? (m.show || item.title) + '  ·  ' + trf('S{s} · E{e}', {s: m.season, e: m.episode}) : item.title;
    setState('');
    infoEl.textContent = item.label;
    fill.style.width = '0';
    timeEl.textContent = '';
    seekBy = 0;
    audioPicked = false;
    if (menuOpen) closeMenu();
    paintIntro();
    layer.className = 'layer on';
    hideHud();
    // The subtitles: the list kept with what's playing (a resume), else read from the Pi.
    if (item.subs.length || !item.subsUrl) chooseSub(); else { showSub(-1); loadSubList(chooseSub); }
    openFlag = true;
    startedAt = Date.now();
    v.src = item.url;
    if (resumeAt > 5) {
      var jump = function () {
        v.removeEventListener('loadedmetadata', jump);
        try { v.currentTime = resumeAt; } catch (e) {}
      };
      v.addEventListener('loadedmetadata', jump);
    }
    var p = v.play();
    if (p && p['catch']) p['catch'](function (x) { log('play() refused: ' + x); });
    clearInterval(saveTimer);
    saveTimer = setInterval(function () { if (!v.paused) save(); }, 10000);
    save();
    changed('state');
  }

  function close() {
    if (!openFlag) return;
    if (v.currentTime) save();
    openFlag = false;
    clearInterval(saveTimer);
    clearTimeout(seekTimer);
    seekBy = 0;
    if (menuOpen) closeMenu();
    // Free the decoder: a 4K stream left loaded holds it.
    try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {}
    subLoading = null;
    cues = [];
    subsEl.innerHTML = '';
    layer.className = 'layer';
    intro.className = 'intro';
    log('closed');
    for (var i = 0; i < closeListeners.length; i++) closeListeners[i]();
    changed('state');
  }

  // --- controls ---------------------------------------------------------------------------------------------------

  function togglePause() {
    if (v.paused) v.play(); else v.pause();
  }

  /** ◀ ▶ add up: the jump happens once the presses stop, so holding the button doesn't queue a seek per press. */
  function seek(seconds) {
    seekBy += seconds;
    paintTime();
    showHud(false);
    clearTimeout(seekTimer);
    seekTimer = setTimeout(function () {
      var to = Math.max(0, v.currentTime + seekBy);
      if (isFinite(v.duration)) to = Math.min(to, v.duration - 1);
      seekBy = 0;
      try { v.currentTime = to; } catch (e) {}
    }, 600);
  }

  function nextAudio() {
    var n = tracks().length;
    if (n < 2) return;
    var list = tracks(), cur = 0;
    for (var i = 0; i < n; i++) if (list[i].enabled) cur = i;
    setAudio((cur + 1) % n);
    showHud(false);
  }

  /** A key while the player is open: true when it's ours (all of them are, while it shows). */
  function key(k) {
    if (!openFlag) return false;
    if (menuOpen) { menuKey(k); return true; }
    if (k === 13 || k === 415 && v.paused || k === 19 && !v.paused) togglePause();
    else if (k === 37 || k === 412) seek(-STEP);
    else if (k === 39 || k === 417) seek(STEP);
    else if (k === 38) openMenu();
    else if (k === 40) { if (hud.className === 'hud hide') showHud(!!v.paused); else hideHud(); }
    else if (k === 461 || k === 10009 || k === 27 || k === 8 || k === 413) close();
    return true;
  }

  /** Subtitles that came after the video ({subsUrl, url}): added to it, and the default one shown. */
  function lateSubs(params) {
    if (!item || params.url !== item.url || !params.subsUrl) return;
    item.subsUrl = params.subsUrl;
    log('subtitles arrived');
    loadSubList(function () {
      if (subIndex < 0 && !item.subPicked) showSub(defaultSub());   // not when you turned them off yourself
      else paintInfo();
      if (menuOpen) paintMenu();
    });
  }

  function command(cmd, params) {
    if (cmd === 'subs') { lateSubs(params || {}); return; }
    if (!openFlag) return;
    if (cmd === 'audio') nextAudio();
    else if (cmd === 'pause') v.pause();
    else if (cmd === 'play') v.play();
    else if (cmd === 'stop') close();
  }

  // --- for the phone (channel.js) ---------------------------------------------------------------------------------

  /** What the TV shows: home, intro (the start screen), playing or paused, with the title and the place. */
  function status() {
    var m = (item && item.meta) || {};
    var on = openFlag && v;
    return {
      screen: !openFlag ? 'home' : introOn() ? 'intro' : (v.paused ? 'paused' : 'playing'),
      title: item ? item.title : null, show: m.show || null, season: m.season || null, episode: m.episode || null,
      episodeTitle: m.episodeTitle || null, poster: item ? item.poster || null : null, backdrop: m.backdrop || null,
      label: item ? item.label || null : null, url: item ? item.url : null, ref: item ? item.ref || null : null,
      position: on ? Math.floor(v.currentTime + seekBy) : 0,
      duration: on && isFinite(v.duration) ? Math.floor(v.duration) : 0,
      buffering: !!(on && !v.paused && v.readyState < 3)
    };
  }

  /** The audio tracks and subtitles on offer, and which ones are on. */
  function trackInfo() {
    var list = openFlag ? tracks() : [], names = trackNames(), audio = [], subs = [];
    for (var i = 0; i < list.length; i++) audio.push({name: names[i], lang: langCode(list[i].language) || null, on: !!list[i].enabled});
    var offered = (openFlag && item && item.subs) || [], snames = subNames();
    for (var j = 0; j < offered.length; j++) subs.push({name: snames[j], lang: langCode(offered[j].lang) || offered[j].lang || null, on: subIndex === j});
    return {audio: audio, subs: subs};
  }

  /** A subtitle by its place (-1: off), remembered as the language to show next time, as the TV's menu does. */
  function pickSub(n) {
    if (!openFlag || !item) return;
    var list = item.subs || [];
    if (n >= list.length) return;
    item.subPicked = true;
    showSub(n);
    setSubPref(n < 0 ? 'off' : langCode(list[n].lang));
    if (menuOpen) paintMenu();
  }

  function seekTo(seconds) {
    if (!openFlag) return;
    var to = Math.max(0, Number(seconds) || 0);
    if (isFinite(v.duration)) to = Math.min(to, v.duration - 1);
    clearTimeout(seekTimer);
    seekBy = 0;
    try { v.currentTime = to; } catch (e) {}
    showHud(false);
    changed('state');
  }

  window.Player = {
    open: open,
    close: close,
    key: key,
    command: command,
    isOpen: function () { return openFlag; },
    /** The saved place ({title, poster, position, duration, url, meta}), for the home screen; null when there's none. */
    current: function () { return openFlag ? null : load(); },
    /** Back into what was playing: where it was left, or from `start` (0: from the beginning). */
    resume: function (start) {
      var s = load();
      if (s) open({url: s.url, title: s.title, poster: s.poster, label: s.label, logUrl: s.logUrl, meta: s.meta, start: start,
                   subs: s.subs, subsUrl: s.subsUrl, ref: s.ref});
    },
    /** The next episode and the episode list come from the Raspberry Pi (the session the phone started). */
    next: function () { if (window.Player.onNext) window.Player.onNext(load()); },
    episodes: function () { if (window.Player.onEpisodes) window.Player.onEpisodes(load()); },
    forget: function () { save(true); },
    onClose: function (fn) { closeListeners.push(fn); },
    status: status,
    tracks: trackInfo,
    setAudio: function (n) { if (openFlag && n >= 0 && n < tracks().length) setAudio(n); },
    setSubtitle: pickSub,
    seekTo: seekTo,
    seekBy: function (seconds) { if (openFlag) seek(Number(seconds) || 0); },
    pause: function () { if (openFlag) v.pause(); },
    play: function () { if (openFlag) v.play(); },
    onChange: function (fn) { changeListeners.push(fn); },
    addCues: addCues,
    parseSubs: parseSubs,
    log: log
  };

  // The Pi's log address from the last video, so what happens before the next one (the phone joining) is kept too.
  var last = load();
  if (last && last.logUrl) logUrl = last.logUrl;
})();
