/*
 * The phone's channel (LG only): the Couchwire app on a phone joins Free My TV through LG's app-to-app gateway and
 * sends it what to play and how (pause, seek, audio, subtitles); Free My TV answers with what it shows, every few
 * seconds while a video plays. Nothing else reaches the TV this way: a phone has to be paired with the TV (its
 * remote control prompt) before LG lets it join.
 *
 * Messages are JSON with v: 1 and a type. From the phone: hello, getState, play {params}, control {action: pause |
 * resume | toggle | seek (to or by, seconds) | stop}, audio {index}, subs {index, -1 = off}; a command may carry an
 * id, answered with ack {id, ok, error}; cues {url, part, cues} (a subtitle's lines). To the phone: state
 * (Player.status()), tracks (Player.tracks()), ack, needSubtitle {url} (read it for me, please), device {macs}
 * (after hello: the TV's network cards, to wake it).
 * ES5, as the rest of web/.
 */
(function () {
  'use strict';

  if (!window.PalmServiceBridge || !window.Player) return;

  var GW = 'luna://com.webos.service.secondscreen.gateway/app2app/host/';
  var bridges = [], clients = {}, tries = 0;

  function log(msg) { Player.log('[channel] ' + msg); }

  function call(method, params, onMessage) {
    var bridge = new window.PalmServiceBridge();
    bridges.push(bridge);
    bridge.onservicecallback = function (raw) {
      var m = null;
      try { m = JSON.parse(raw); } catch (e) {}
      if (m && onMessage) onMessage(m);
      else if (m && m.returnValue === false) log(method + ' failed: ' + (m.errorText || raw));
      // One-off calls are done after their answer: let the bridge go.
      if (!onMessage) {
        for (var i = 0; i < bridges.length; i++) if (bridges[i] === bridge) { bridges.splice(i, 1); break; }
      }
    };
    try { bridge.call(GW + method, JSON.stringify(params)); } catch (e) { log(method + ' threw ' + e); }
  }

  function send(clientId, message) {
    message.v = 1;
    call('sendMessage', {clientId: clientId, payload: message});
  }

  function broadcast(message) {
    for (var id in clients) if (clients.hasOwnProperty(id)) send(id, message);
  }

  function stateMessage() {
    var s = Player.status();
    s.type = 'state';
    return s;
  }

  function tracksMessage() {
    var t = Player.tracks();
    t.type = 'tracks';
    return t;
  }

  // --- what the phone asks ----------------------------------------------------------------------------------------

  function control(p) {
    var action = p.action;
    if (action === 'pause') Player.pause();
    else if (action === 'resume' || action === 'play') Player.play();
    else if (action === 'toggle') { if (Player.status().screen === 'paused') Player.play(); else Player.pause(); }
    else if (action === 'seek') { if (p.to !== undefined) Player.seekTo(p.to); else Player.seekBy(p.by); }
    else if (action === 'stop') Player.close();
    else return 'Unknown action: ' + action;
    return null;
  }

  function handle(from, p) {
    var error = null;
    if (!p || typeof p !== 'object') return;
    if (p.type === 'hello' || p.type === 'getState') {
      clients[from] = true;
      send(from, stateMessage());
      send(from, tracksMessage());
      if (p.type === 'hello') sendDevice(from);
      return;
    } else if (p.type === 'play') {
      var params = p.params || {};
      if (!params.url) error = 'Nothing to play';
      else if (!(window.FreeMyTV && window.FreeMyTV.play(params))) error = 'The TV could not open it';
      else log('play "' + (params.title || '') + '" from the phone');
    } else if (p.type === 'control') {
      error = control(p);
    } else if (p.type === 'audio') {
      Player.setAudio(Number(p.index));
    } else if (p.type === 'subs') {
      Player.setSubtitle(Number(p.index));
    } else if (p.type === 'cues') {
      Player.addCues(p.url, p.cues || [], p.part === 0);
    } else {
      error = 'Unknown message: ' + p.type;
    }
    if (p.id !== undefined) send(from, {type: 'ack', id: p.id, ok: !error, error: error});
  }

  /** The TV's network cards (MACs), which the phone needs to wake it later with Wake-on-LAN. */
  function sendDevice(to) {
    var bridge = new window.PalmServiceBridge();
    bridges.push(bridge);
    bridge.onservicecallback = function (raw) {
      var m = null, macs = [];
      try { m = JSON.parse(raw); } catch (e) {}
      for (var i = 0; i < bridges.length; i++) if (bridges[i] === bridge) { bridges.splice(i, 1); break; }
      if (!m || m.returnValue === false) { log('network info: ' + (m && m.errorText || 'no answer')); return; }
      var cards = [m.wiredInfo, m.wifiInfo];
      for (var j = 0; j < cards.length; j++) {
        if (cards[j] && cards[j].macAddress) macs.push(cards[j].macAddress);
      }
      if (macs.length) send(to, {type: 'device', macs: macs});
    };
    try { bridge.call('luna://com.webos.service.connectionmanager/getinfo', '{}'); } catch (e) {}
  }

  // --- the gateway ------------------------------------------------------------------------------------------------

  function onEvent(m) {
    if (m.returnValue === false) {
      // After a relaunch the gateway can still hold the last registration for a few seconds.
      if (/already/i.test(m.errorText || '') && tries < 12) { setTimeout(register, 5000); return; }
      log('registration failed: ' + (m.errorText || JSON.stringify(m)));
      return;
    }
    if (m.subscribed && !m.type) { log('ready for phones'); return; }
    var p = m.payload || {};
    var from = m.from || m.clientId || (p.client && p.client.id) || null;
    if (m.type === 'p2p.join-request' && p.requestId) {
      call('sendJoinResponse', {requestId: p.requestId, allowJoin: true});
      if (from) clients[from] = true;
      log('phone joined');
    } else if (m.type === 'p2p.join') {
      if (from) clients[from] = true;
    } else if (m.type === 'p2p.depart') {
      if (from) delete clients[from];
      log('phone left');
    } else if (m.type === 'p2p' && from) {
      clients[from] = true;
      handle(from, p);
    }
  }

  function register() {
    tries++;
    call('registerAppChannel', {subscribe: true}, onEvent);
  }

  // --- what the phone hears ---------------------------------------------------------------------------------------

  // A subtitle the TV couldn't read itself: the phone reads it and sends its lines ('cues').
  Player.onNeedSubtitle = function (url) { broadcast({type: 'needSubtitle', url: url}); };

  Player.onChange(function (kind) {
    broadcast(kind === 'tracks' ? tracksMessage() : stateMessage());
  });

  // The place, every 5 s while something plays (the phone's progress bar and the account's resume point).
  setInterval(function () {
    var message = stateMessage();
    if (message.screen === 'playing' || message.screen === 'intro') broadcast(message);
  }, 5000);

  register();
})();
