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
    const numberSelected = Boolean(document.querySelector('#numberGrid .number-button.selected'));
    const pairSelected = document.querySelectorAll('#pairNumberGrid .number-button.selected').length === 2;
    if (numberButton && (!roundOpen('numberRoundStatus') || !numberSelected)) numberButton.disabled = true;
    if (pairButton && (!roundOpen('pairRoundStatus') || !pairSelected)) pairButton.disabled = true;
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
    for (const id of ['numberGrid','pairNumberGrid']) {
      const grid = $(id);
      if (grid) new MutationObserver(sync).observe(grid, {subtree:true, attributes:true, attributeFilter:['class']});
    }
    sync();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
  else init();
})();