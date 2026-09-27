(() => {
  'use strict';

  const tasks = new Map();
  const TICK_MS = 250;

  function intervalFor(task) {
    const raw = typeof task.interval === 'function' ? task.interval() : task.interval;
    const n = Number(raw);
    return Number.isFinite(n) ? Math.max(250, n) : 5000;
  }

  function scheduleNext(task, from = Date.now()) {
    task.nextAt = from + intervalFor(task);
  }

  async function runTask(task, force = false) {
    if (!task || task.running) return;
    if (!force && task.visibleOnly && document.visibilityState !== 'visible') {
      scheduleNext(task);
      return;
    }
    if (!force && typeof task.when === 'function' && !task.when()) {
      scheduleNext(task);
      return;
    }

    task.running = true;
    try {
      await task.run();
      task.lastRunAt = Date.now();
      task.lastError = '';
    } catch (error) {
      task.lastError = String(error?.message || error || 'Erro de sincronização');
      if (!task.silent) console.warn('ludo sync', task.name, task.lastError);
    } finally {
      task.running = false;
      scheduleNext(task);
    }
  }

  function tick() {
    const now = Date.now();
    for (const task of tasks.values()) {
      if (task.nextAt <= now) runTask(task);
    }
  }

  function register(name, run, options = {}) {
    if (!name || typeof run !== 'function') throw new Error('Tarefa de sincronização inválida.');
    const task = {
      name: String(name),
      run,
      interval: options.interval ?? 5000,
      when: typeof options.when === 'function' ? options.when : null,
      visibleOnly: options.visibleOnly !== false,
      silent: options.silent !== false,
      running: false,
      nextAt: options.immediate === false ? Date.now() + 1 : 0,
      lastRunAt: 0,
      lastError: ''
    };
    tasks.set(task.name, task);
    if (options.immediate !== false) queueMicrotask(() => runTask(task));
    return () => tasks.delete(task.name);
  }

  function unregister(name) {
    tasks.delete(String(name));
  }

  function kick(name) {
    const task = tasks.get(String(name));
    if (!task) return false;
    task.nextAt = 0;
    queueMicrotask(tick);
    return true;
  }

  function kickAll() {
    for (const task of tasks.values()) task.nextAt = 0;
    queueMicrotask(tick);
  }

  function stats() {
    return [...tasks.values()].map((task) => ({
      name: task.name,
      intervalMs: intervalFor(task),
      running: task.running,
      nextInMs: Math.max(0, task.nextAt - Date.now()),
      lastRunAt: task.lastRunAt,
      lastError: task.lastError
    }));
  }

  const timer = setInterval(tick, TICK_MS);

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') kickAll();
  });
  window.addEventListener('focus', kickAll);
  window.addEventListener('pageshow', kickAll);
  window.addEventListener('beforeunload', () => clearInterval(timer), { once: true });

  window.JLLudoSync = Object.freeze({
    register,
    unregister,
    kick,
    kickAll,
    stats
  });
})();