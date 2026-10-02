(() => {
  'use strict';

  function create({input,minus,plus,min=.5,max=500,step=.5}={}) {
    if(!input)return null;

    const clamp=value=>Math.min(max,Math.max(min,Math.round((Number(value)||min)*100)/100));
    const render=value=>{
      const next=clamp(value);
      input.value=String(next);
      if(minus)minus.disabled=next<=min;
      if(plus)plus.disabled=next>=max;
      return next;
    };
    const change=delta=>{
      const current=Number(input.value);
      render((Number.isFinite(current)?current:min)+delta);
      input.dispatchEvent(new Event('input',{bubbles:true}));
      input.dispatchEvent(new Event('change',{bubbles:true}));
    };

    minus?.addEventListener('click',()=>change(-step));
    plus?.addEventListener('click',()=>change(step));
    input.addEventListener('input',()=>{
      const value=Number(input.value);
      if(Number.isFinite(value)){
        if(minus)minus.disabled=value<=min;
        if(plus)plus.disabled=value>=max;
      }
    });
    input.addEventListener('blur',()=>render(input.value));
    render(input.value||min);

    return Object.freeze({value:()=>Number(input.value),render});
  }

  function attachAll({root=document}={}) {
    return [1,2].map(slot=>{
      const suffix=slot===1?'':String(slot);
      return create({
        input:root.querySelector('#aviatorAmount'+suffix),
        minus:root.querySelector('#aviatorAmountMinus'+suffix),
        plus:root.querySelector('#aviatorAmountPlus'+suffix)
      });
    });
  }

  window.JLAviatorAmountStepper=Object.freeze({create,attachAll});
})();
