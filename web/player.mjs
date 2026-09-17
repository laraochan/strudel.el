// SPDX-License-Identifier: AGPL-3.0-or-later
// One persistent runtime; evaluating replaces its entire pattern.
let state = 'loading';
let events = [];
let runtime;
let repl;
let busy = false;
let generation = 0;
let enabled = false;
let audioInit;
const status = document.getElementById('state');
const error = document.getElementById('error');

function setState(value) {
  state = value;
  status.textContent = value;
}

function report(reason, id) {
  const message = reason?.message || String(reason);
  error.textContent = message;
  events.push({ type: 'error', id, message });
  setState('error');
}

window.addEventListener('error', event => report(event.error || event.message));
window.addEventListener('unhandledrejection', event => report(event.reason));
document.addEventListener('securitypolicyviolation', event =>
  report(`Offline player blocked external resource: ${event.blockedURI}`));

async function enableAudio() {
  setState('starting-audio');
  let timeout;
  try {
    // Called from Emacs' execute-script, or from the fallback button.  Resume
    // synchronously here to retain any user activation granted by WebKit.
    const context = runtime.getAudioContext();
    const resumed = context.resume();
    audioInit ??= runtime.initAudio().catch(reason => {
      audioInit = undefined;
      throw reason;
    });
    await Promise.race([
      Promise.all([resumed, audioInit]),
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error('Click Enable audio to allow playback.')), 2000);
      }),
    ]);
    if (context.state !== 'running') throw new Error('Click Enable audio to allow playback.');
    enabled = true;
    error.textContent = '';
    setState(repl.scheduler.started ? 'playing' : 'ready');
  } catch (reason) {
    error.textContent = reason.message;
    setState('enable-audio');
  } finally {
    clearTimeout(timeout);
  }
}

async function command(request) {
  if (request.type === 'enable') return enableAudio();
  if (request.type === 'stop') {
    generation++;
    repl?.stop();
    events.push({ type: 'stopped' });
    if (enabled) setState('stopped');
    return;
  }
  if (request.type !== 'eval') return;
  if (!enabled) return report('Enable audio in the Strudel buffer first.', request.id);
  if (busy) return report('Evaluation is still pending. Stop or wait before evaluating again.', request.id);
  const current = generation;
  busy = true;
  error.textContent = '';
  try {
    // Compile without autoplay, so Stop during an async evaluation cannot
    // restart the scheduler when that evaluation eventually resolves.
    await repl.evaluate(request.code, false);
    if (current !== generation) {
      repl.stop();
      events.push({ type: 'cancelled', id: request.id });
      return;
    }
    if (repl.state.evalError) throw repl.state.evalError;
    if (!repl.scheduler.started) await repl.start();
    if (current !== generation) repl.stop();
    else setState('playing');
    events.push({ type: 'evaluated', id: request.id });
  } catch (reason) {
    report(reason, request.id);
  } finally {
    busy = false;
  }
}

window.strudelEmacs = {
  command,
  drain() {
    const result = { state, events };
    events = [];
    return result;
  },
};

document.getElementById('stop').addEventListener('click', () => command({ type: 'stop' }));
document.getElementById('enable').addEventListener('click', enableAudio);

try {
  runtime = await import('./runtime/dist/index.mjs');
  runtime.setLogger((message, type) => {
    if (type === 'error' || /error:|not found/i.test(message)) report(message);
  });
  document.addEventListener('strudel.log', ({ detail }) => {
    if (!busy && (detail.type === 'error' || /error:/i.test(detail.message))) report(detail.message);
  });
  // The player stays hidden. WebKit throttles window timers in that state.
  // One worker timer drives the one scheduler without changing its semantics.
  const clockURL = URL.createObjectURL(new Blob([`
    let timer;
    onmessage = ({ data: delay }) => {
      clearInterval(timer);
      if (delay) timer = setInterval(() => postMessage(null), delay);
    };
  `], { type: 'text/javascript' }));
  const clock = new Worker(clockURL);
  URL.revokeObjectURL(clockURL);
  clock.onerror = event => report(event.message);
  let tick;
  clock.onmessage = () => tick?.();
  repl = await runtime.initStrudel({
    setInterval(callback, delay) {
      tick = callback;
      clock.postMessage(delay);
      return 1;
    },
    clearInterval() {
      tick = undefined;
      clock.postMessage(0);
    },
  });
  const response = await fetch('./samples/strudel.json');
  if (!response.ok) throw new Error('Cannot read the local sample manifest.');
  const map = await response.json();
  await runtime.samples(map);
  const names = Object.keys(map).filter(name => name !== '_base');
  document.getElementById('samples').textContent = names.join(', ') || 'none (synths available)';
  document.getElementById('enable').disabled = false;
  setState('loaded');
} catch (reason) { report(reason); }
