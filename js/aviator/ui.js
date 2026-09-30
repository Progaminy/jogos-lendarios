(() => {
  'use strict';

  function create({$,getRound,getBetState,multiplier}) {
    function money(value){
      const n=Number(value);
      return (Number.isFinite(n)?n:0).toLocaleString('pt-MZ',{
        minimumFractionDigits:2,
        maximumFractionDigits:2
      })+' MZN';
    }

    function moneyCompact(value){
      const n=Number(value);
      return (Number.isFinite(n)?n:0).toLocaleString('pt-MZ',{
        minimumFractionDigits:0,
        maximumFractionDigits:2
      })+' MZN';
    }

    function playerMessage(error,fallback='Não foi possível concluir. Tente novamente.'){
      const raw=String(error?.message||error||'')
        .replace(/\\n|\r|\n/g,' ')
        .replace(/\s+/g,' ')
        .trim();

      const rules=[
        [/RATE_LIMITED|BOT_RATE_LIMITED|BOT_TOO_FAST|muitas requisi[cç][oõ]es|rápidas demais/i,'Muitas ações em pouco tempo. Aguarde um momento e tente novamente.'],
        [/saldo insuficiente/i,'Saldo insuficiente.'],
        [/jogador bloqueado/i,'A sua conta está bloqueada.'],
        [/aviator em manutencao|aviator brevemente/i,'Aviator brevemente.'],
        [/nao ha rodada aviator aberta|apostas fechadas/i,'Apostas fechadas. Aguarde a próxima rodada.'],
        [/valor de aposta invalido|informe um valor/i,'Informe um valor de aposta válido.'],
        [/cash-out automatico deve ser/i,'Verifique o valor do cash-out automático.'],
        [/ja existe uma aposta nesta rodada/i,'A sua aposta desta rodada já foi confirmada.'],
        [/aposta nao encontrada/i,'Aposta não encontrada. Atualize o jogo.'],
        [/aposta ja liquidada/i,'Esta aposta já terminou.'],
        [/voo nao esta ativo/i,'O voo já terminou.'],
        [/crash ja atingido/i,'Fim da rodada. Cash-out não disponível.'],
        [/sem liga[cç][aã]o|failed to fetch|network/i,'Sem ligação. Verifique a internet.'],
        [/reserva da banca inconsistente/i,'Não foi possível concluir agora. Tente novamente.']
      ];
      for(const [pattern,message] of rules){
        if(pattern.test(raw))return message;
      }
      return fallback;
    }

    function show(selector,visible){
      const el=typeof selector==='string'?$(selector):selector;
      if(el)el.classList.toggle('hidden',!visible);
    }

    function setStagePhase(phase){
      const stage=$('#aviatorStage');
      if(!stage)return;
      const next='is-'+phase;
      if(stage.classList.contains(next))return;
      stage.classList.remove('is-open','is-locked','is-flying','is-crashed','is-waiting');
      stage.classList.add(next);
    }

    function multiplierTier(value){
      const n=Number(value);
      if(!Number.isFinite(n)||n<2)return 'low';
      if(n<10)return 'medium';
      return 'high';
    }

    function applyMultiplierTier(el,value){
      if(!el)return;
      const next='tier-'+multiplierTier(value);
      if(el.classList.contains(next))return;
      el.classList.remove('tier-low','tier-medium','tier-high');
      el.classList.add(next);
    }

    function renderMultiplier(value){
      const el=$('#multiplier');
      if(!el)return;
      const n=Number(value);
      const safe=Number.isFinite(n)&&n>=1?n:1;
      const text=safe.toFixed(2)+'×';
      if(el.textContent!==text)el.textContent=text;
      const isLong=text.length>=8;
      if(el.classList.contains('long')!==isLong)el.classList.toggle('long',isLong);
      applyMultiplierTier(el,safe);
    }

    function resetCashout(){
      renderCashoutAction({
        active:false,
        disabled:true,
        pending:false,
        multiplier:null,
        stake:0,
        status:'Disponível durante o voo'
      });
    }

    function createCashoutGestureGuard(button,{maxTravelPx=14}={}){
      let pointer=null;
      const supportsPointer=typeof globalThis.PointerEvent==='function';

      const clear=()=>{pointer=null;};

      button?.addEventListener('pointerdown',event=>{
        if(button.disabled){
          clear();
          return;
        }
        if(event.pointerType==='mouse'&&event.button!==0){
          clear();
          return;
        }
        pointer={
          id:event.pointerId,
          x:Number(event.clientX)||0,
          y:Number(event.clientY)||0,
          moved:false
        };
      },{passive:true});

      button?.addEventListener('pointermove',event=>{
        if(!pointer||pointer.id!==event.pointerId||pointer.moved)return;
        const dx=(Number(event.clientX)||0)-pointer.x;
        const dy=(Number(event.clientY)||0)-pointer.y;
        if(Math.hypot(dx,dy)>maxTravelPx)pointer.moved=true;
      },{passive:true});

      button?.addEventListener('pointercancel',clear,{passive:true});

      function shouldAcceptClick(event){
        if(event?.detail===0||!supportsPointer)return true;
        const accepted=Boolean(pointer)&&!pointer.moved;
        clear();
        return accepted;
      }

      return Object.freeze({shouldAcceptClick});
    }

    function renderCashoutAction({
      active=false,
      disabled=true,
      pending=false,
      multiplier=null,
      stake=0,
      status=''
    }={}){
      const wrap=$('#cashoutAction');
      const button=$('#cashoutBtn');
      const statusEl=$('#cashoutActionStatus');
      const m=Number(multiplier);
      const s=Number(stake);
      const hasMultiplier=Number.isFinite(m)&&m>=1;
      const hasStake=Number.isFinite(s)&&s>0;

      const priority=Boolean(active)&&!disabled&&!pending;
      if(wrap){
        if(wrap.classList.contains('is-priority')!==priority){
          wrap.classList.toggle('is-priority',priority);
        }
        if(wrap.classList.contains('is-pending')!==Boolean(pending)){
          wrap.classList.toggle('is-pending',Boolean(pending));
        }
      }

      if(button){
        const nextDisabled=Boolean(disabled);
        const nextText=pending
          ?'Confirmando cash-out…'
          :active&&hasMultiplier
            ?'Cash-out · '+m.toFixed(2)+'×'
            :'Cash-out';
        if(button.disabled!==nextDisabled)button.disabled=nextDisabled;
        if(button.textContent!==nextText)button.textContent=nextText;
      }

      if(statusEl){
        const nextStatus=status
          ?String(status)
          :active&&hasMultiplier&&hasStake
            ?moneyCompact(s)+' × '+m.toFixed(2)+' = '+money(s*m)
            :'Disponível durante o voo';
        if(statusEl.textContent!==nextStatus)statusEl.textContent=nextStatus;
      }
    }

    function renderRoundNumber(){
      const round=getRound?.();
      const el=$('#roundNumber');
      const roundNo=Number(round?.round_no);
      const internalId=Number(round?.id);
      const displayNo=Number.isFinite(roundNo)&&roundNo>0
        ?roundNo
        :Number.isFinite(internalId)&&internalId>0?internalId:null;
      if(el)el.textContent=displayNo?'#'+displayNo:'—';
    }

    function setBetInputsLocked(locked){
      const value=Boolean(locked);
      const amount=$('#aviatorAmount');
      const auto=$('#aviatorAutoCashout');
      if(amount)amount.disabled=value;
      if(auto)auto.disabled=value;
    }

    function renderBetAction({disabled=false,status='Disponível'}={}){
      const button=$('#betBtn');
      const statusEl=$('#betActionStatus');
      if(button){
        button.textContent='Apostar';
        button.disabled=Boolean(disabled);
      }
      if(statusEl)statusEl.textContent=String(status||'');
    }

    function renderTicket(multiplierValue=null){
      const round=getRound?.();
      const state=getBetState?.()||{};
      const panel=$('#activeBetPanel');
      if(!panel)return;

      const active=Boolean(state.myBet)&&state.myStake>0;
      panel.classList.toggle('hidden',!active);
      if(!active)return;

      $('#activeBetStake').textContent=money(state.myStake);
      const auto=$('#activeBetAuto');
      if(auto)auto.textContent=state.myAutoCashout
        ?'Auto '+Number(state.myAutoCashout).toFixed(2)+'×'
        :'Auto desligado';

      if(round?.status==='FLYING'){
        const m=Number(multiplierValue??multiplier?.());
        const safeMultiplier=Number.isFinite(m)&&m>=1?m:1;
        $('#activeBetMultiplier').textContent=safeMultiplier.toFixed(2)+'×';
        $('#activeBetPayout').textContent=money(state.myStake*safeMultiplier);
      }else{
        $('#activeBetMultiplier').textContent='A aguardar';
        $('#activeBetPayout').textContent=money(state.myStake);
      }
    }

    function renderBetConfirmation(){
      const round=getRound?.();
      const state=getBetState?.()||{};
      const box=$('#betConfirmation');
      const text=$('#betConfirmationText');
      const auto=$('#betConfirmationAuto');
      if(!box||!text)return;

      const visible=
        Boolean(state.myBet)&&
        state.myStake>0&&
        ['OPEN','LOCKED'].includes(round?.status);

      box.classList.toggle('hidden',!visible);
      if(!visible)return;

      text.textContent='Aposta confirmada: '+moneyCompact(state.myStake);
      if(auto){
        const hasAuto=Number.isFinite(Number(state.myAutoCashout))&&Number(state.myAutoCashout)>=1.01;
        auto.classList.toggle('hidden',!hasAuto);
        auto.textContent=hasAuto?'Auto cash-out: '+Number(state.myAutoCashout).toFixed(2)+'×':'';
      }
    }

    function renderBetResult(result=null){
      const panel=$('#betResultPanel');
      const icon=$('#betResultIcon');
      const label=$('#betResultLabel');
      const detail=$('#betResultDetail');
      if(!panel||!icon||!label||!detail)return;

      const status=String(result?.status||'').toUpperCase();
      const stake=Number(result?.stake);
      const payout=Number(result?.payout);
      const multiplier=Number(result?.cashout_multiplier);

      panel.classList.remove('is-won','is-lost','is-refunded');

      if(!['CASHED_OUT','LOST','REFUNDED'].includes(status)){
        panel.classList.add('hidden');
        panel.removeAttribute('data-result');
        return;
      }

      panel.classList.remove('hidden');

      if(status==='CASHED_OUT'){
        panel.classList.add('is-won');
        panel.dataset.result='won';
        icon.textContent='✓';
        label.textContent='GANHA';
        detail.textContent=Number.isFinite(payout)
          ?'Recebido '+money(payout)+(Number.isFinite(multiplier)?' · '+multiplier.toFixed(2)+'×':'')
          :'Cash-out confirmado';
        return;
      }

      if(status==='LOST'){
        panel.classList.add('is-lost');
        panel.dataset.result='lost';
        icon.textContent='✕';
        label.textContent='PERDIDA';
        detail.textContent=Number.isFinite(stake)&&stake>0
          ?'Valor perdido '+money(stake)
          :'Rodada encerrada sem cash-out';
        return;
      }

      panel.classList.add('is-refunded');
      panel.dataset.result='refunded';
      icon.textContent='↩';
      label.textContent='REEMBOLSADA';
      detail.textContent=Number.isFinite(stake)&&stake>0
        ?'Devolvido '+money(stake)
        :'Valor devolvido ao saldo';
    }


    return Object.freeze({
      money,moneyCompact,playerMessage,show,setStagePhase,multiplierTier,
      applyMultiplierTier,renderMultiplier,resetCashout,createCashoutGestureGuard,renderCashoutAction,renderRoundNumber,
      setBetInputsLocked,renderBetAction,renderTicket,renderBetConfirmation,renderBetResult
    });
  }

  window.JLAviatorUI=Object.freeze({create});
})();
