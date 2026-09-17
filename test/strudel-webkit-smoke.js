// SPDX-License-Identifier: AGPL-3.0-or-later
// Run through strudel-webkit-smoke.el in the example project's player.
// Generates low-volume audio briefly and stops even if an assertion fails.
(async () => {
  const checks = [];
  const check = (name, value) => {
    if (!value) throw new Error(name);
    checks.push(name);
  };
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const player = window.strudelEmacs;
  const m = await import('./runtime/dist/index.mjs');
  let meter;
  try {
    check('audio enabled without a click', document.getElementById('state').textContent === 'ready');
    check('AudioContext running', m.getAudioContext().state === 'running');
    check('AudioWorklet available', !!m.getAudioContext().audioWorklet);
    check('local manifest registered', document.getElementById('samples').textContent.includes('kick'));

    let peak = 0;
    meter = setInterval(() => {
      const a = m.getAnalyserById(1);
      const data = new Float32Array(a.fftSize);
      a.getFloatTimeDomainData(data);
      peak = Math.max(peak, ...data.map(Math.abs));
    }, 25);
    await player.command({type: 'eval', id: 9001,
      code: 's("kick*8 snare*8 hat*8").gain(0.08).analyze(1)'});
    await sleep(1600);
    check('local WAV generates nonzero audio', peak > 0.00001);
    await player.command({type: 'eval', id: 9006,
      code: 'note("c3").s("sine").gain(0.03).legato(2).analyze(1)'});
    // Outlast the initial note: a hidden window timer can stop scheduling
    // even though the AudioContext and the cycle counter keep advancing.
    await sleep(4500);
    for (let i = 0; i < 3; i++) {
      const a = m.getAnalyserById(1);
      const data = new Float32Array(a.fftSize);
      a.getFloatTimeDomainData(data);
      check(`background audio continues (${i + 1})`, data.some(value => Math.abs(value) > 0.00001));
      await sleep(750);
    }
    const before = m.getTime();
    await player.command({type: 'eval', id: 9002,
      code: '$: s("hat*8").gain(0.05)\n$: note("c3 eb3 g3").s("triangle").gain(0.03).analyze(1)'});
    check('live update preserves cycle clock', m.getTime() >= before - 0.1);
    check('multiple dollar tracks evaluate', document.getElementById('error').textContent === '');

    await player.command({type: 'eval', id: 9003, code: 's("unterminated)'});
    check('syntax error reported', document.getElementById('error').textContent.length > 0);
    await player.command({type: 'eval', id: 9004, code: 's("hat*8").gain(0.03)'});
    check('evaluation recovers after error', document.getElementById('error').textContent === '');

    const pending = player.command({type: 'eval', id: 9005,
      code: 'await new Promise(r => setTimeout(r, 200)); s("kick").gain(0.03)'});
    await sleep(50);
    await player.command({type: 'stop'});
    await pending;
    await sleep(250);
    check('stop cancels pending autoplay', m.getTime() === 0);

    const resources = performance.getEntriesByType('resource').map(entry => entry.name);
    check('all fetched resources are local', resources.every(url =>
      url.startsWith(location.origin + '/') || url.startsWith('blob:') || url.startsWith('data:')));
    check('sample audio fetched from local server', resources.some(url => url.endsWith('/samples/kick.wav')));
    window.strudelSmokeResult = {passed: true, checks, peak, resources};
  } catch (error) {
    window.strudelSmokeResult = {passed: false, checks, error: error.message};
  } finally {
    clearInterval(meter);
    await player.command({type: 'stop'});
  }
})();
null;
