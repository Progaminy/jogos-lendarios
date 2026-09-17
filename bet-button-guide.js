(() => {
  'use strict';
  if (window.__JL_BET_BUTTON_GUIDE__) return;
  window.__JL_BET_BUTTON_GUIDE__ = true;

  const $ = (id) => document.getElementById(id);

  function roundOpen(statusId) {
    return /apostas abertas/i.test($(statusId)?.textContent || '');
  }

  function sync() {
    const numberButton = $('betButton');
    const pairButton = $('pairBetButton');
    if (numberButton && roundOpen('numberRoundStatus') && numberButton.disabled) numberButton.disabled = false;
    if (pairButton && roundOpen('pairRoundStatus') && pairButton.disabled) pairButton.disabled = false;
  }

  function init() {
    for (const id of ['betButton','pairBetButton']) {
      const button = $(id);
      if (button) new MutationObserver(sync).observe(button, {attributes:true, attributeFilter:['disabled']});
    }
    for (const id of ['numberRoundStatus','pairRoundStatus']) {
      const status = $(id);
      if (status) new MutationObserver(sync).observe(status, {childList:true,characterData:true,subtree:true});
    }
    sync();
    setInterval(sync, 350);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
  else init();
})();