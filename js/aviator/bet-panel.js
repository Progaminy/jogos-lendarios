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
    const queuedNextBetStorageKey='jl_aviator_next_bet_v1_slot_'+slot;
    let queuedNextBet=readQueuedNextBet();
    let queuedBetAttemptedRoundId=null;
    let queuedBetSubmittingRoundId=null;

    const round=()=>getRound?.()||null;
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
        wrap.classList.toggle('is-cancel',mode==='cancel');
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
        cashoutButton.textContent=pending
          ?'Confirmando cash-out…'
          :active&&hasMultiplier&&hasStake
            ?'Cash-out · '+money(stake*m)
            :'Cash-out';
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

    function readQueuedNextBet(){
      try{
        const parsed=JSON.parse(sessionStorage.getItem(queuedNextBetStorageKey)||'null');
        const amount=Number(parsed?.amount);
        const auto=parsed?.auto_cashout===null?null:Number(parsed?.auto_cashout);
        if(!Number.isFinite(amount)||amount<0.5||amount>500)return null;
        if(auto!==null&&(!Number.isFinite(auto)||auto<1.01))return null;
        return {amount,auto_cashout:auto};
      }catch(_){
        return null;
      }
    }

    function saveQueuedNextBet(value){
      queuedNextBet=value||null;
      try{
        if(queuedNextBet)sessionStorage.setItem(queuedNextBetStorageKey,JSON.stringify(queuedNextBet));
        else sessionStorage.removeItem(queuedNextBetStorageKey);
      }catch(_){}
    }

    function scheduleQueuedNextBet(){
      const r=round();
      const roundId=Number(r?.id);
      if(
        !queuedNextBet||
        !enabled()||
        !online()||
        !playerToken()||
        !Number.isFinite(roundId)||
        r?.status!=='OPEN'||
        r?.betting_open===false||
        betId||
        betting||
        queuedBetAttemptedRoundId===roundId
      ) return;

      queuedBetAttemptedRoundId=roundId;
      queueMicrotask(()=>{
        const current=round();
        if(
          !queuedNextBet||
          !online()||
          !playerToken()||
          Number(current?.id)!==roundId||
          current?.status!=='OPEN'||
          current?.betting_open===false||
          betId||
          betting
        ) return;

        const amount=$('#aviatorAmount'+suffix);
        const auto=$('#aviatorAutoCashout'+suffix);
        if(amount)amount.value=String(queuedNextBet.amount);
        if(auto)auto.value=queuedNextBet.auto_cashout===null?'':String(queuedNextBet.auto_cashout);
        queuedBetSubmittingRoundId=roundId;
        form?.requestSubmit?.();
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
        status.textContent=round()?.status==='OPEN'
          ?'A preparar envio'
          :'Próxima aposta preparada';
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
        betting||
        autoBetAttemptedRoundId===roundId||
        Boolean(queuedNextBet)
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
        setInputsLocked(!online()||!enabled());
        renderBetAction({disabled:true,status:'Aguarde a próxima rodada'});
        resetCashout();
        renderTicket();
        renderConfirmation();
        return;
      }

      if(r.status==='OPEN'){
        const closed=r.betting_open===false||Number(secondsToClose?.())===0;
        const inputsLocked=!enabled()||!online()||Boolean(betId)||betting||closed;
        const canCancel=enabled()&&online()&&Boolean(betId)&&!betting&&!closed;
        setInputsLocked(inputsLocked);

        if(canCancel){
          renderBetAction({
            disabled:false,
            status:'Aposta confirmada · toque para cancelar',
            label:'Cancelar',
            mode:'cancel'
          });
        }else{
          renderBetAction({
            disabled:inputsLocked,
            status:betId
              ?closed?'Apostas fechadas':'Aposta confirmada'
              :closed?'Apostas fechadas':'Disponível'
          });
        }

        resetCashout();
        renderTicket();
        renderConfirmation();
        scheduleQueuedNextBet();
        scheduleAutoBet();
        return;
      }

      if(r.status==='LOCKED'){
        setInputsLocked(!online()||!enabled()||Boolean(queuedNextBet));
        renderBetAction({
          disabled:!online()||!enabled(),
          status:queuedNextBet?'Próxima aposta preparada':'Prepare a próxima rodada',
          label:queuedNextBet?'Cancelar':'Apostar',
          mode:queuedNextBet?'cancel-next':'queue-next'
        });
        resetCashout();
        renderTicket();
        renderConfirmation();
        if(betId&&message)message.textContent='Aposta confirmada. Aguardando descolagem.';
        return;
      }

      if(r.status==='FLYING'){
        setInputsLocked(!online()||!enabled()||Boolean(betId)||Boolean(queuedNextBet));
        renderBetAction({
          disabled:Boolean(betId)||!online()||!enabled(),
          status:betId
            ?'Apostas fechadas'
            :queuedNextBet
              ?'Próxima aposta preparada'
              :'Prepare a próxima rodada',
          label:queuedNextBet?'Cancelar':'Apostar',
          mode:queuedNextBet?'cancel-next':'queue-next',
          hidden:Boolean(betId)
        });
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

      setInputsLocked(!online()||!enabled());
      renderBetAction({disabled:true,status:'Aguarde a próxima rodada'});
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
      queuedBetAttemptedRoundId=null;
      queuedBetSubmittingRoundId=null;
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

      const action=String(betButton?.dataset.action||'bet');

      if(action==='queue-next'||action==='cancel-next'){
        if(action==='cancel-next'){
          saveQueuedNextBet(null);
          if(message)message.textContent='Próxima aposta cancelada.';
          renderRound();
          return;
        }

        try{
          if(!online())throw new Error('Sem ligação. Aguarde a reconexão.');
          if(!playerToken())throw new Error('Entre na sua conta primeiro.');
          if(!enabled())throw new Error('Aviator brevemente.');
          if(!round()||!['LOCKED','FLYING'].includes(round().status)){
            throw new Error('Aguarde a rodada em curso.');
          }

          const amount=Number($('#aviatorAmount'+suffix)?.value);
          if(!Number.isFinite(amount)||amount<0.5||amount>500){
            throw new Error('Informe um valor entre 0,50 e 500 MZN.');
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

          saveQueuedNextBet({amount,auto_cashout:auto});
          if(message)message.textContent='';
        }catch(error){
          if(message)message.textContent=playerMessage(
            error,
            'Não foi possível preparar a próxima aposta.'
          );
        }
        renderRound();
        return;
      }

      const autoTriggered=
        action==='bet'&&autoBetSubmittingRoundId===Number(round()?.id);
      const queuedTriggered=
        action==='bet'&&queuedBetSubmittingRoundId===Number(round()?.id);
      betting=true;

      if(action==='cancel'){
        const id=betId;
        const oldStake=stake;
        renderBetAction({
          disabled:true,
          status:'Cancelando aposta…',
          label:'Cancelar',
          mode:'cancel'
        });

        try{
          if(!online())throw new Error('Sem ligação. Aguarde a reconexão.');
          if(!playerToken())throw new Error('Entre na sua conta primeiro.');
          if(!id||round()?.status!=='OPEN'||round()?.betting_open===false){
            throw new Error('Cancelamento encerrado para esta rodada.');
          }

          const result=await financial.cancelBet(
            id,
            financial.cancelBetRequestKey(id)
          );

          renderResult({
            status:'REFUNDED',
            stake:oldStake,
            payout:Number(result.refund)||oldStake
          });
          betId=null;
          stake=0;
          autoCashout=null;
          if(message){
            message.textContent='Aposta cancelada. '+
              money(Number(result.refund)||oldStake)+' devolvidos.';
          }
        }catch(error){
          if(message)message.textContent=playerMessage(
            error,
            'Não foi possível cancelar a aposta.'
          );
        }finally{
          betting=false;
          renderRound();
        }
        return;
      }

      renderBetAction({
        disabled:true,
        status:'Confirmando aposta…'
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
          throw new Error('Informe um valor entre 0,50 e 500 MZN.');
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

        if(queuedTriggered){
          saveQueuedNextBet(null);
          queuedBetAttemptedRoundId=Number(round()?.id);
        }

        if(message){
          message.textContent=queuedTriggered
            ?'Aposta preparada confirmada nesta rodada.'
            :autoTriggered
              ?'Aposta automática confirmada para esta rodada.'
              :'Aposta confirmada. Aguarde a descolagem.';
        }
      }catch(error){
        if(message)message.textContent=playerMessage(
          error,
          'Não foi possível confirmar a aposta.'
        );
      }finally{
        if(autoBetSubmittingRoundId===Number(round()?.id)){
          autoBetSubmittingRoundId=null;
        }
        if(queuedBetSubmittingRoundId===Number(round()?.id)){
          queuedBetSubmittingRoundId=null;
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
