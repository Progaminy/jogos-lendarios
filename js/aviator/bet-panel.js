(() => {
  'use strict';

  function create({
    slot=2,
    $,
    financial,
    playerToken,
    getRound,
    isEnabled,
    isOnline,
    multiplier,
    secondsToClose,
    money,
    moneyCompact,
    playerMessage,
    sound,
    personalHistory,
    createGestureGuard
  }) {
    const suffix=String(slot);
    const form=$('#aviatorBetForm'+suffix);
    const betButton=$('#betBtn'+suffix);
    const cashoutButton=$('#cashoutBtn'+suffix);
    const message=$('#aviatorMessage'+suffix);
    const gestureGuard=createGestureGuard?.(cashoutButton)||{shouldAcceptClick:()=>true};

    let betId=null;
    let stake=0;
    let autoCashout=null;
    let betting=false;
    let cashingOut=false;
    let autoRecoveryRoundId=null;
    let autoBetEnabled=sessionStorage.getItem('jl_aviator_auto_bet_v1_slot_'+slot)==='1';
    let autoBetAttemptedRoundId=null;
    let autoBetSubmittingRoundId=null;
    let betResultTimer=0;

    const round=()=>getRound?.()||null;
    const nextBet=window.JLAviatorNextBet?.create({
      slot,
      $,
      playerToken,
      getRound:round,
      isEnabled,
      isOnline,
      isBusy:()=>betting,
      hasActiveBet:()=>Boolean(betId),
      playerMessage,
      form,
      onMessage:text=>{
        if(message)message.textContent=String(text||'');
      }
    })||null;
    const online=()=>Boolean(isOnline?.());
    const enabled=()=>Boolean(isEnabled?.());

    function setInputsLocked(locked){
      const amount=$('#aviatorAmount'+suffix);
      const auto=$('#aviatorAutoCashout'+suffix);
      if(amount)amount.disabled=Boolean(locked);
      if(auto)auto.disabled=Boolean(locked);
    }

    function renderBetAction({
      disabled=false,
      status='Disponível',
      label='Apostar',
      mode='bet',
      hidden=false
    }={}){
      const wrap=$('.aviator-bet-action-'+suffix);
      const statusEl=$('#betActionStatus'+suffix);
      if(wrap){
        wrap.classList.toggle('hidden',Boolean(hidden));
        wrap.classList.toggle('is-cancel',mode==='cancel'||mode==='cancel-next');
      }
      if(betButton){
        betButton.textContent=String(label||'Apostar');
        betButton.disabled=Boolean(disabled);
        betButton.dataset.action=String(mode||'bet');
      }
      if(statusEl)statusEl.textContent=String(status||'');
    }

    function renderCashout({
      active=false,
      disabled=true,
      pending=false,
      value=null,
      status=''
    }={}){
      const wrap=$('#cashoutAction'+suffix);
      const statusEl=$('#cashoutActionStatus'+suffix);
      const m=Number(value);
      const hasMultiplier=Number.isFinite(m)&&m>=1;
      const hasStake=Number.isFinite(stake)&&stake>0;
      const priority=Boolean(active)&&!disabled&&!pending;

      if(wrap){
        wrap.classList.toggle('hidden',!active&&!pending);
        wrap.classList.toggle('is-priority',priority);
        wrap.classList.toggle('is-pending',Boolean(pending));
      }
      if(cashoutButton){
        cashoutButton.disabled=Boolean(disabled);
        const liveReturn=active&&hasMultiplier&&hasStake?money(stake*m):null;
        cashoutButton.textContent=pending?'Confirmando…':liveReturn||'Sacar';
      }
      if(statusEl){
        statusEl.textContent=status
          ?String(status)
          :active&&hasMultiplier&&hasStake
            ?moneyCompact(stake)+' × '+m.toFixed(2)+' = '+money(stake*m)
            :'Disponível durante o voo';
      }
    }

    function resetCashout(){
      renderCashout({
        active:false,
        disabled:true,
        pending:false,
        value:null,
        status:'Disponível durante o voo'
      });
    }

    function renderTicket(value=null){
      const panel=$('#activeBetPanel'+suffix);
      if(!panel)return;
      const active=Boolean(betId)&&stake>0;
      panel.classList.toggle('hidden',!active);
      if(!active)return;

      $('#activeBetStake'+suffix).textContent=money(stake);
      $('#activeBetAuto'+suffix).textContent=autoCashout
        ?'Auto '+Number(autoCashout).toFixed(2)+'×'
        :'Auto desligado';

      if(round()?.status==='FLYING'){
        const m=Number(value??multiplier?.());
        const safe=Number.isFinite(m)&&m>=1?m:1;
        $('#activeBetMultiplier'+suffix).textContent=safe.toFixed(2)+'×';
        $('#activeBetPayout'+suffix).textContent=money(stake*safe);
      }else{
        $('#activeBetMultiplier'+suffix).textContent='A aguardar';
        $('#activeBetPayout'+suffix).textContent=money(stake);
      }
    }

    function renderConfirmation(){
      const box=$('#betConfirmation'+suffix);
      const text=$('#betConfirmationText'+suffix);
      const auto=$('#betConfirmationAuto'+suffix);
      if(!box||!text)return;

      const visible=Boolean(betId)&&stake>0&&['OPEN','LOCKED'].includes(round()?.status);
      box.classList.toggle('hidden',!visible);
      if(!visible)return;

      text.textContent='Aposta confirmada: '+moneyCompact(stake);
      if(auto){
        const hasAuto=Number.isFinite(Number(autoCashout))&&Number(autoCashout)>=1.01;
        auto.classList.toggle('hidden',!hasAuto);
        auto.textContent=hasAuto?'Auto cash-out: '+Number(autoCashout).toFixed(2)+'×':'';
      }
    }

    function renderResult(result=null){
      clearTimeout(betResultTimer);
      betResultTimer=0;
      const panel=$('#betResultPanel'+suffix);
      const icon=$('#betResultIcon'+suffix);
      const label=$('#betResultLabel'+suffix);
      const detail=$('#betResultDetail'+suffix);
      if(!panel||!icon||!label||!detail)return;

      const status=String(result?.status||'').toUpperCase();
      const resultStake=Number(result?.stake);
      const payout=Number(result?.payout);
      const resultMultiplier=Number(result?.cashout_multiplier);

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
          ?'Recebido '+money(payout)+(Number.isFinite(resultMultiplier)?' · '+resultMultiplier.toFixed(2)+'×':'')
          :'Cash-out confirmado';
        betResultTimer=setTimeout(()=>{
          panel.classList.add('hidden');
          panel.removeAttribute('data-result');
          betResultTimer=0;
        },3000);
      }else if(status==='LOST'){
        panel.classList.add('is-lost');
        panel.dataset.result='lost';
        icon.textContent='✕';
        label.textContent='PERDIDA';
        detail.textContent=Number.isFinite(resultStake)&&resultStake>0
          ?'Valor perdido '+money(resultStake)
          :'Rodada encerrada sem cash-out';
      }else{
        panel.classList.add('is-refunded');
        panel.dataset.result='refunded';
        icon.textContent='↩';
        label.textContent='REEMBOLSADA';
        detail.textContent=Number.isFinite(payout)&&payout>0
          ?'Devolvido '+money(payout)
          :Number.isFinite(resultStake)&&resultStake>0
            ?'Devolvido '+money(resultStake)
            :'Valor devolvido';
      }

      personalHistory?.invalidate?.();
    }

    function renderResultFromBet(bet){
      if(!bet){
        renderResult(null);
        return;
      }
      const status=String(bet.status||'').toUpperCase();
      if(!['CASHED_OUT','LOST','REFUNDED'].includes(status)){
        if(status==='ACTIVE')renderResult(null);
        return;
      }
      renderResult({
        status,
        stake:Number(bet.stake),
        payout:Number(bet.payout),
        cashout_multiplier:Number(bet.cashout_multiplier)
      });
    }

    function renderAutoBetStatus(){
      const toggle=$('#aviatorAutoBet'+suffix);
      const status=$('#aviatorAutoBetStatus'+suffix);
      if(toggle&&toggle.checked!==autoBetEnabled)toggle.checked=autoBetEnabled;
      if(!status)return;

      if(!autoBetEnabled){
        status.textContent='Desligado';
      }else if(!playerToken()){
        status.textContent='Entre na conta';
      }else if(round()?.status==='OPEN'&&betId){
        status.textContent='Confirmada nesta rodada';
      }else{
        status.textContent=round()?.status==='OPEN'?'Ativo':'Aguardando';
      }
    }

    function scheduleAutoBet(){
      renderAutoBetStatus();
      const r=round();
      const roundId=Number(r?.id);

      if(
        !autoBetEnabled||
        !enabled()||
        !online()||
        !playerToken()||
        !Number.isFinite(roundId)||
        r?.status!=='OPEN'||
        r?.betting_open===false||
        betId||
        nextBet?.hasQueued?.()||
        betting||
        autoBetAttemptedRoundId===roundId
      ) return;

      autoBetAttemptedRoundId=roundId;
      queueMicrotask(()=>{
        const current=round();
        if(
          !autoBetEnabled||
          !online()||
          !playerToken()||
          Number(current?.id)!==roundId||
          current?.status!=='OPEN'||
          current?.betting_open===false||
          betId||
          nextBet?.hasQueued?.()||
          betting
        ) return;

        autoBetSubmittingRoundId=roundId;
        form?.requestSubmit?.();
      });
    }

    function renderRound(){
      const r=round();
      renderAutoBetStatus();

      if(!r){
        setInputsLocked(true);
        renderBetAction({
          disabled:true,
          status:'A carregar',
          label:'Apostar',
          mode:'bet'
        });
        resetCashout();
        renderTicket();
        renderConfirmation();
        return;
      }

      if(r.status==='OPEN'){
        const closed=r.betting_open===false||Number(secondsToClose?.())===0;
        const queued=Boolean(nextBet?.hasQueued?.());
        const inputsLocked=!enabled()||!online()||Boolean(betId)||queued||betting||closed;
        setInputsLocked(inputsLocked);

        renderBetAction({
          disabled:inputsLocked,
          status:betId
            ?'Aposta confirmada'
            :queued
              ?'A enviar aposta'
              :closed?'Apostas fechadas':'Disponível',
          label:betId||queued?'Foi apostado':'Apostar',
          mode:betId||queued?'confirmed':'bet'
        });

        resetCashout();
        renderTicket();
        renderConfirmation();
        if(!closed)nextBet?.schedule?.();
        scheduleAutoBet();
        return;
      }

      if(r.status==='LOCKED'){
        setInputsLocked(true);
        renderBetAction({
          disabled:true,
          status:betId?'Aposta confirmada':'Apostas fechadas',
          label:betId?'Foi apostado':'Aguarde',
          mode:betId?'confirmed':'locked'
        });
        resetCashout();
        renderTicket();
        renderConfirmation();
        if(betId&&message)message.textContent='Aposta confirmada. Aguarde o voo.';
        return;
      }

      if(r.status==='FLYING'){
        const queued=Boolean(nextBet?.hasQueued?.());
        const canQueue=enabled()&&online()&&!betId&&!queued&&!betting;
        setInputsLocked(!canQueue);
        renderBetAction({
          disabled:!canQueue,
          status:betId
            ?'Aposta em voo'
            :queued
              ?'Aposta registada para a próxima rodada'
              :'Aposte para a próxima rodada',
          label:betId||queued?'Foi apostado':'Apostar',
          mode:betId||queued?'confirmed':'bet',
          hidden:Boolean(betId)
        });
        if(!betId&&!queued&&message&&/^Aposta confirmada/i.test(message.textContent||'')){
          message.textContent='';
        }
        renderCashout({
          active:Boolean(betId),
          disabled:!online()||!betId||cashingOut,
          pending:cashingOut,
          value:multiplier?.(),
          stake
        });
        renderTicket(multiplier?.());
        renderConfirmation();
        return;
      }

      setInputsLocked(true);
      renderBetAction({
        disabled:true,
        status:'Aguarde a próxima rodada',
        label:'Aguarde',
        mode:'locked'
      });
      resetCashout();
      renderTicket();
      renderConfirmation();
    }

    function betSlotOf(bet){
      return Number(bet?.bet_slot)===2?2:1;
    }

    function activeBetForRound(bets,roundId){
      return (Array.isArray(bets)?bets:[])
        .filter(b=>
          Number(b?.round_id)===Number(roundId)&&
          b?.status==='ACTIVE'&&
          betSlotOf(b)===Number(slot)
        )
        .sort((a,b)=>Number(b?.id)-Number(a?.id))[0]||null;
    }

    function latestBetForRound(bets,roundId){
      return (Array.isArray(bets)?bets:[])
        .filter(b=>
          Number(b?.round_id)===Number(roundId)&&
          betSlotOf(b)===Number(slot)
        )
        .sort((a,b)=>Number(b?.id)-Number(a?.id))[0]||null;
    }

    function applyPlayerState(player){
      const bets=Array.isArray(player?.bets)?player.bets:[];
      const roundId=Number(round()?.id);
      const current=Number.isFinite(roundId)?activeBetForRound(bets,roundId):null;
      const latest=Number.isFinite(roundId)?latestBetForRound(bets,roundId):null;

      betId=current?.id??null;
      stake=current?Number(current.stake)||0:0;
      autoCashout=current?Number(current.auto_cashout_multiplier)||null:null;
      if(current)renderResult(null);

      if(!current&&latest){
        if(latest.status==='CASHED_OUT'){
          financial.clearPendingCashout(slot);
          renderResultFromBet(latest);
          if(message)message.textContent=financial.cashoutMessage(
            latest.cashout_source,
            latest.cashout_multiplier,
            latest.payout
          );
        }else if(latest.status==='LOST'){
          financial.clearPendingCashout(slot);
          renderResultFromBet(latest);
          if(message)message.textContent='Fim da rodada. A aposta foi perdida.';
        }else if(latest.status==='REFUNDED'){
          financial.clearPendingCashout(slot);
          renderResultFromBet(latest);
          if(message)message.textContent='A aposta foi reembolsada pelo servidor.';
        }
      }

      renderRound();
    }

    async function refreshStatus(){
      if(!betId||!playerToken()||!round())return false;
      const requestedBetId=Number(betId);
      const requestedRoundId=Number(round().id);

      try{
        const bet=await financial.fetchBetStatus(requestedBetId);
        if(!bet||Number(round()?.id)!==requestedRoundId)return false;

        if(bet.status==='ACTIVE'){
          stake=Number(bet.stake)||stake;
          autoCashout=Number(bet.auto_cashout_multiplier)||null;
          renderResult(null);
          renderRound();
          return true;
        }

        betId=null;
        stake=0;
        autoCashout=null;
        resetCashout();
        renderResultFromBet(bet);
        renderRound();

        if(bet.status==='CASHED_OUT'&&message){
          message.textContent=financial.cashoutMessage(
            bet.cashout_source,
            bet.cashout_multiplier,
            bet.payout
          );
        }else if(bet.status==='LOST'&&message){
          message.textContent='Fim da rodada. Cash-out não disponível.';
        }else if(bet.status==='REFUNDED'&&message){
          message.textContent='A aposta foi reembolsada pelo servidor.';
        }
        return true;
      }catch(_){
        return false;
      }
    }

    async function reconcilePendingCashout(){
      const pending=financial.readPendingCashout(slot);
      if(!pending||!online()||!playerToken())return false;

      try{
        const bet=await financial.fetchBetStatus(pending.bet_id);
        if(!bet)return false;

        if(bet.status==='ACTIVE'){
          financial.clearPendingCashout(slot);
          if(Number(round()?.id)===pending.round_id){
            betId=bet.id;
            stake=Number(bet.stake)||0;
            autoCashout=Number(bet.auto_cashout_multiplier)||null;
          }
          renderResult(null);
          if(message)message.textContent='Cash-out não foi confirmado. A aposta continua ativa.';
          renderRound();
          return true;
        }

        financial.clearPendingCashout(slot);
        betId=null;
        stake=0;
        autoCashout=null;
        renderResultFromBet(bet);
        renderRound();

        if(bet.status==='CASHED_OUT'&&message){
          message.textContent=financial.cashoutMessage(
            bet.cashout_source,
            bet.cashout_multiplier,
            bet.payout
          );
        }else if(bet.status==='LOST'&&message){
          message.textContent='Fim da rodada. Cash-out não disponível.';
        }else if(bet.status==='REFUNDED'&&message){
          message.textContent='A aposta foi reembolsada pelo servidor.';
        }
        return true;
      }catch(_){
        return false;
      }
    }

    function onRoundChanged(){
      betId=null;
      stake=0;
      autoCashout=null;
      autoRecoveryRoundId=null;
      autoBetAttemptedRoundId=null;
      nextBet?.resetRound?.();
      resetCashout();
      renderTicket();
      renderConfirmation();
      void reconcilePendingCashout();
    }

    function setConnectionState(connected){
      if(!connected){
        renderBetAction({disabled:true,status:'Sem ligação'});
        renderCashout({
          active:Boolean(betId)&&round()?.status==='FLYING',
          disabled:true,
          pending:false,
          value:multiplier?.(),
          status:betId?'Sem ligação — cash-out indisponível':'Disponível durante o voo'
        });
      }else{
        renderRound();
      }
    }

    function paintFlight(value){
      if(round()?.status!=='FLYING')return;
      renderTicket(value);
      renderCashout({
        active:Boolean(betId),
        disabled:!online()||!betId||cashingOut,
        pending:cashingOut,
        value
      });

      if(
        betId&&
        autoCashout&&
        Number(round()?.id)!==Number(autoRecoveryRoundId)&&
        Number(value)>=autoCashout
      ){
        autoRecoveryRoundId=Number(round().id);
        void refreshStatus();
      }
    }

    async function submit(event){
      event.preventDefault();
      if(betting)return;

      if(round()?.status!=='OPEN'){
        if(['FLYING','CRASHED','SETTLED'].includes(round()?.status)){
          nextBet?.queue?.();
          renderRound();
          return;
        }
        if(message)message.textContent='Apostas fechadas.';
        renderRound();
        return;
      }

      const queuedTriggered=Boolean(nextBet?.isSubmitting?.(round()?.id));
      const autoTriggered=
        autoBetSubmittingRoundId===Number(round()?.id);
      betting=true;

      renderBetAction({
        disabled:true,
        status:'Confirmando aposta…',
        label:'Apostar',
        mode:'bet'
      });

      try{
        if(!online())throw new Error('Sem ligação. Aguarde a reconexão.');
        if(!playerToken())throw new Error('Entre na sua conta primeiro.');
        if(!enabled())throw new Error('Aviator brevemente.');
        if(round()?.status!=='OPEN'||round()?.betting_open===false){
          throw new Error('Apostas fechadas.');
        }

        const amount=Number($('#aviatorAmount'+suffix)?.value);
        if(!Number.isFinite(amount)||amount<0.5||amount>500){
          throw new Error('Informe um valor entre 0,50 e 500.');
        }

        const autoRaw=String($('#aviatorAutoCashout'+suffix)?.value||'').trim();
        const auto=autoRaw===''?null:Number(autoRaw);
        if(
          auto!==null&&(
            !Number.isFinite(auto)||
            auto<1.01||
            Math.abs(auto*100-Math.round(auto*100))>1e-8
          )
        ){
          throw new Error('Cash-out automático deve ser 1,01x ou maior, com até 2 casas decimais.');
        }

        const result=await financial.placeBetSlot({
          slot,
          amount,
          requestKey:financial.betKeyForSlot(slot),
          autoCashoutMultiplier:auto
        });

        renderResult(null);
        betId=result.bet_id;
        stake=Number(result.stake);
        autoCashout=Number(result.auto_cashout_multiplier)||null;
        sound?.playBet?.();

        if(queuedTriggered)nextBet?.consume?.(round()?.id);
        if(message){
          message.textContent=autoTriggered
            ?'Aposta automática confirmada para esta rodada.'
            :'Aposta confirmada. Aguarde o voo.';
        }
      }catch(error){
        if(queuedTriggered)nextBet?.fail?.(round()?.id);
        if(message)message.textContent=playerMessage(
          error,
          'Não foi possível confirmar a aposta.'
        );
      }finally{
        if(autoBetSubmittingRoundId===Number(round()?.id)){
          autoBetSubmittingRoundId=null;
        }
        betting=false;
        renderRound();
      }
    }

    async function cashout(event){
      event.preventDefault();
      if(!gestureGuard.shouldAcceptClick(event))return;

      if(!online()){
        if(message)message.textContent='Sem ligação. Cash-out indisponível até reconectar.';
        return;
      }
      if(cashingOut||!betId||round()?.status!=='FLYING')return;

      cashingOut=true;
      const id=betId;
      const oldStake=stake;
      const roundId=Number(round().id);
      const requestKey=financial.cashoutRequestKey(id);
      financial.savePendingCashout(id,roundId,requestKey,slot);

      renderCashout({
        active:true,
        disabled:true,
        pending:true,
        value:multiplier?.(),
        status:'A confirmar no servidor'
      });

      try{
        const result=await financial.requestFinancialCashout(id,requestKey);
        financial.clearPendingCashout(slot);
        renderResult({
          status:'CASHED_OUT',
          stake:oldStake,
          payout:Number(result.payout),
          cashout_multiplier:Number(result.multiplier)
        });
        sound?.playCashout?.();
        betId=null;
        stake=0;
        autoCashout=null;
        if(message)message.textContent=financial.cashoutMessage(
          result.source,
          result.multiplier,
          result.payout
        );
      }catch(error){
        const reconciled=await reconcilePendingCashout();
        if(!reconciled&&message){
          message.textContent=playerMessage(
            error,
            'Não foi possível confirmar o cash-out.'
          );
        }
      }finally{
        cashingOut=false;
        renderRound();
      }
    }

    function attach(){
      form?.addEventListener('submit',submit);
      cashoutButton?.addEventListener('click',cashout);

      const autoToggle=$('#aviatorAutoBet'+suffix);
      if(autoToggle){
        autoToggle.checked=autoBetEnabled;
        autoToggle.addEventListener('change',()=>{
          autoBetEnabled=Boolean(autoToggle.checked);
          try{
            sessionStorage.setItem(
              'jl_aviator_auto_bet_v1_slot_'+slot,
              autoBetEnabled?'1':'0'
            );
          }catch(_){}
          if(!autoBetEnabled){
            autoBetSubmittingRoundId=null;
            autoBetAttemptedRoundId=null;
          }
          renderAutoBetStatus();
          if(autoBetEnabled)scheduleAutoBet();
        });
      }

      renderAutoBetStatus();
      renderRound();
    }

    attach();

    return Object.freeze({
      renderRound,
      paintFlight,
      applyPlayerState,
      refreshOnStatusChange:refreshStatus,
      reconcilePendingCashout,
      onRoundChanged,
      setConnectionState,
      hasActiveBet:()=>Boolean(betId),
      getBetId:()=>betId
    });
  }

  window.JLAviatorBetPanel=Object.freeze({create});
})();
