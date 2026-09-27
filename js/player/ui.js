(() => {
  'use strict';

  function removeOldPlayerSummary(){
    document.querySelector('#playerBetSummary')?.remove();

    document.querySelectorAll('#playerArea .bet-summary-grid').forEach((grid)=>{
      const host=grid.closest('section');
      if(host && host.id!=='playerArea') host.remove();
      else grid.remove();
    });

    document.querySelectorAll('#playerArea .bet-summary-note').forEach((el)=>el.remove());
  }

  let summaryQueued=false;
  function queueSummaryCleanup(){
    if(summaryQueued)return;
    summaryQueued=true;
    requestAnimationFrame(()=>{
      summaryQueued=false;
      removeOldPlayerSummary();
    });
  }

  function ensureCopyNotice(){
    let notice=document.getElementById('jlCopyNotice');
    if(notice)return notice;

    notice=document.createElement('div');
    notice.id='jlCopyNotice';
    notice.setAttribute('role','status');
    notice.setAttribute('aria-live','polite');
    Object.assign(notice.style,{
      position:'fixed',
      zIndex:'99999',
      left:'50%',
      top:'86px',
      transform:'translate(-50%,-10px)',
      opacity:'0',
      pointerEvents:'none',
      padding:'12px 18px',
      borderRadius:'12px',
      border:'1px solid rgba(78,213,138,.55)',
      background:'#10251b',
      color:'#c8f7d9',
      boxShadow:'0 16px 44px rgba(0,0,0,.52)',
      fontWeight:'900',
      fontSize:'.9rem',
      transition:'opacity .18s ease, transform .18s ease'
    });
    document.body.appendChild(notice);
    return notice;
  }

  function showCopyNotice(message,ok=true){
    const notice=ensureCopyNotice();
    notice.textContent=message;
    notice.style.borderColor=ok?'rgba(78,213,138,.55)':'rgba(255,116,116,.55)';
    notice.style.background=ok?'#10251b':'#2a1518';
    notice.style.color=ok?'#c8f7d9':'#ffd1d1';
    notice.style.opacity='1';
    notice.style.transform='translate(-50%,0)';
    clearTimeout(showCopyNotice.timer);
    showCopyNotice.timer=setTimeout(()=>{
      notice.style.opacity='0';
      notice.style.transform='translate(-50%,-10px)';
    },2200);
  }

  async function copyNumber(){
    const value='869954518';
    if(navigator.clipboard?.writeText){
      try{
        await navigator.clipboard.writeText(value);
        return true;
      }catch{}
    }

    const input=document.createElement('textarea');
    input.value=value;
    input.readOnly=true;
    input.style.position='fixed';
    input.style.opacity='0';
    document.body.appendChild(input);
    input.select();
    input.setSelectionRange(0,value.length);
    let copied=false;
    try{copied=document.execCommand('copy');}catch{}
    input.remove();
    return copied;
  }

  document.addEventListener('click',async(event)=>{
    const button=event.target.closest('#copyDepositPhone,#quickCopyDepositPhone');
    if(!button)return;

    event.preventDefault();
    event.stopImmediatePropagation();

    const copied=await copyNumber();
    showCopyNotice(copied?'Número copiado':'Não foi possível copiar',copied);

    if(copied){
      const oldText=button.textContent;
      button.textContent='Copiado ✓';
      setTimeout(()=>{
        if(button.isConnected)button.textContent=oldText||'Copiar';
      },1800);
    }
  },true);

  removeOldPlayerSummary();

  const observer=new MutationObserver(queueSummaryCleanup);
  observer.observe(document.body,{childList:true,subtree:true});
})();