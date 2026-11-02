/* Round 4 (accepts joins with {requestId, allowJoin}; answers messages): LG's app-to-app channel with the gateway's real methods (found on the TV):
 *   app2app/host/registerAppChannel  (subscribe: phones joining, and their messages)
 *   app2app/host/sendJoinResponse    (accept a phone)
 *   app2app/host/sendMessage         (to a phone)
 * Everything the gateway answers is shown here and sent to the Pi's log. ES5. */
(function () {
  var GW = 'luna://com.webos.service.secondscreen.gateway/app2app/host/';
  var LOG_URL = 'http://192.168.1.35:8080/api/player/log';
  var lines = [], pending = [], bridges = [];
  function log(msg) {
    var line = new Date().toISOString().slice(11, 19) + ' ' + msg;
    lines.push(line);
    if (lines.length > 30) lines.shift();
    document.getElementById('log').textContent = lines.join('\n');
    pending.push('[channel4] ' + line);
  }
  setInterval(function () {
    if (!pending.length) return;
    var batch = pending; pending = [];
    try { var x = new XMLHttpRequest(); x.open('POST', LOG_URL, true); x.setRequestHeader('Content-Type', 'text/plain'); x.send(JSON.stringify({lines: batch})); } catch (e) {}
  }, 1000);
  function short(v) { var s; try { s = typeof v === 'string' ? v : JSON.stringify(v); } catch (e) { s = String(v); } return s.length > 500 ? s.slice(0, 500) + '…' : s; }

  function call(method, params, name, onMsg) {
    var b = new window.PalmServiceBridge();
    bridges.push(b);
    b.onservicecallback = function (raw) {
      log(name + ' <- ' + short(raw));
      var m = null;
      try { m = JSON.parse(raw); } catch (e) {}
      if (m && onMsg) onMsg(m);
    };
    try { b.call(GW + method, JSON.stringify(params)); log(name + ' -> ' + short(params)); } catch (e) { log(name + ' threw ' + e); }
  }

  log('round 4 started as ' + (window.PalmSystem && window.PalmSystem.identifier));

  // A phone joining: {type: 'p2p.join-request', payload: {requestId, client: {id, ...}}} -> accept it.
  // Anything else from a phone: answered, the likely shapes at once (the gateway's errors name the right one).
  var clients = {}, answered = 0;
  function onEvent(m) {
    var p = m.payload || {};
    if (m.type === 'p2p.join-request' && p.requestId) {
      if (p.client && p.client.id) clients[p.client.id] = true;
      call('sendJoinResponse', {requestId: p.requestId, allowJoin: true}, 'join(allowJoin)');
      return;
    }
    if (m.returnValue === true && m.subscribed) return;   // the registration itself
    var from = m.from || m.clientId || p.from || p.clientId || (p.client && p.client.id) || null;
    if (!from) { for (var k in clients) from = k; }
    if (!from || answered >= 2) return;
    answered++;
    var reply = {echo: p.message || p.payload || p || null, n: answered, from: 'tv'};
    call('sendMessage', {clientId: from, payload: reply}, 'send(clientId,payload)');
    call('sendMessage', {to: from, payload: reply}, 'send(to,payload)');
    call('sendMessage', {clientId: from, message: reply}, 'send(clientId,message)');
    call('sendMessage', {client: from, payload: reply}, 'send(client,payload)');
  }

  // Registered once; when the gateway says one exists already, again a few times (a stale one may expire).
  var tries = 0;
  function register() {
    tries++;
    call('registerAppChannel', {subscribe: true}, 'registerAppChannel #' + tries, function (m) {
      if (m.returnValue === false && /already/i.test(m.errorText || '') && tries < 6) { setTimeout(register, 5000); return; }
      onEvent(m);
    });
  }
  register();

  document.addEventListener('webOSRelaunch', function (e) { log('webOSRelaunch: ' + short(e.detail)); }, true);
  document.addEventListener('keydown', function (e) { if (e.keyCode === 461 || e.keyCode === 27) { try { window.close(); } catch (x) {} } });
})();
