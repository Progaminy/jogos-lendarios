(() => {
  'use strict';

  const STORAGE_KEY = 'jl_financial_requests_v1';

  function newKey() {
    if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
    const bytes = new Uint8Array(16);
    globalThis.crypto?.getRandomValues?.(bytes);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
      || `${Date.now()}-${Math.random()}`;
  }

  function store() {
    try { return JSON.parse(sessionStorage.getItem(STORAGE_KEY) || '{}') || {}; }
    catch { return {}; }
  }

  function requestKey(scope, args) {
    const payload = { ...args };
    delete payload.p_token;
    delete payload.p_idempotency_key;
    const fingerprint = JSON.stringify(payload);
    const currentStore = store();
    const current = currentStore[scope];

    if (current?.fingerprint === fingerprint && current?.key) return current.key;

    const key = newKey();
    currentStore[scope] = { fingerprint, key };
    try { sessionStorage.setItem(STORAGE_KEY, JSON.stringify(currentStore)); } catch {}
    return key;
  }

  function clearKey(scope, key) {
    const currentStore = store();
    if (currentStore[scope]?.key !== key) return;
    delete currentStore[scope];
    try { sessionStorage.setItem(STORAGE_KEY, JSON.stringify(currentStore)); } catch {}
  }

  async function rpc(scope, name, args) {
    const key = requestKey(scope, args);
    const result = await window.JLApi.rpc(name, { ...args, p_idempotency_key: key });
    clearKey(scope, key);
    return result;
  }

  window.JLFinancial = Object.freeze({ rpc });
})();