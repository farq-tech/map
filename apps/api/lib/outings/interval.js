'use strict';

/**
 * setInterval that never overlaps itself: if the previous run has not finished when the next tick comes
 * (a slow database, thousands of outings), the tick is skipped. `track` receives each run's promise
 * (graceful shutdown waits on them); errors are logged by name, never thrown.
 */
function createGuardedInterval(ms, name, work, { track = () => {}, log = (...a) => console.warn(...a), setIntervalFn = setInterval } = {}) {
  let running = false;
  let skipped = 0;
  const timer = setIntervalFn(() => {
    if (running) {
      skipped += 1;
      return;
    }
    running = true;
    track(
      Promise.resolve()
        .then(work)
        .catch((e) => log(`[outings] ${name}:`, e.code || e.message))
        .finally(() => {
          running = false;
        }),
    );
  }, ms);
  timer.unref?.();
  return { timer, skipped: () => skipped, running: () => running, stop: () => clearInterval(timer) };
}

module.exports = { createGuardedInterval };
