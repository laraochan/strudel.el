// SPDX-License-Identifier: AGPL-3.0-or-later
// One persistent runtime; evaluating replaces its entire pattern.
let state = 'loading';
let events = [];
let runtime;
let repl;
let busy = false;
let generation = 0;
let enabled = false;
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

async function command(request) {
  if (request.type === 'stop') {
    generation++;
    repl?.stop();
    setState(enabled ? 'stopped' : 'enable-audio');
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
document.getElementById('enable').addEventListener('click', async () => {
  try {
    await runtime.initAudio();
    if (runtime.getAudioContext().state !== 'running') {
      throw new Error('Audio is suspended. Click Enable audio again.');
    }
    enabled = true;
    setState('ready');
  } catch (reason) { report(reason); }
});

try {
  runtime = await import('./runtime/dist/index.mjs');
  runtime.setLogger((message, type) => {
    if (type === 'error' || /error:|not found/i.test(message)) report(message);
  });
  document.addEventListener('strudel.log', ({ detail }) => {
    if (!busy && (detail.type === 'error' || /error:/i.test(detail.message))) report(detail.message);
  });
  repl = await runtime.initStrudel();
  const response = await fetch('./samples/strudel.json');
  if (!response.ok) throw new Error('Cannot read the local sample manifest.');
  const map = await response.json();
  await runtime.samples(map);
  const names = Object.keys(map).filter(name => name !== '_base');
  document.getElementById('samples').textContent = names.join(', ') || 'none (synths available)';
  document.getElementById('enable').disabled = false;
  setState('enable-audio');
} catch (reason) { report(reason); }
