(() => {
  'use strict';

  function create(deps) {
    const {
      $,
      state,
      rpc,
      money,
      dateTime,
      escapeHtml,
      toast,
      adminFinancialRequestKey,
      clearAdminFinancialRequestKey
    } = deps;

    let aviatorBankLedgerBusy=false;
    let aviatorBankLedgerLastLoad=0;
    let aviatorAuditBusy=false;
    let aviatorAuditLastLoad=0;
    
    function aviatorBankMovementLabel(type){
      if(type==='cashout')return 'Lucro pago no cash-out';
      if(type==='lost_stake')return 'Stake perdido creditado';
      return 'Ajuste manual';
    }
    
    async function refreshAviatorBankLedger(force=false){
      const wrap=$('aviatorBankLedgerWrap');
      const host=$('aviatorBankLedger');
      const status=$('aviatorBankLedgerStatus');
      if(!wrap||!host||!state.token)return;
      if(!wrap.open&&!force)return;
      if(aviatorBankLedgerBusy)return;
      if(!force&&Date.now()-aviatorBankLedgerLastLoad<10000)return;
    
      aviatorBankLedgerBusy=true;
      if(status)status.textContent='A carregar…';
    
      try{
        const rows=await rpc('jl_aviator_admin_bank_ledger',{
          p_token:state.token,
          p_limit:30
        });
    
        const items=Array.isArray(rows)?rows:[];
        if(!items.length){
          host.innerHTML='<p class="muted">Ainda não há movimentos registados.</p>';
        }else{
          host.innerHTML=items.map(item=>{
            const delta=Number(item.delta)||0;
            const deltaClass=delta>0?'positive':delta<0?'negative':'neutral';
            const sign=delta>0?'+':'';
            return '<div class="aviator-bank-ledger-row">'+
              '<div class="aviator-bank-ledger-main">'+
                '<strong>'+escapeHtml(aviatorBankMovementLabel(item.type))+'</strong>'+
                '<small>'+escapeHtml(item.reason||'—')+'</small>'+
              '</div>'+
              '<div class="aviator-bank-ledger-value '+deltaClass+'">'+
                '<strong>'+sign+money(delta)+' MZN</strong>'+
                '<small>Saldo: '+money(item.balance_after)+' MZN</small>'+
              '</div>'+
              '<time>'+escapeHtml(dateTime(item.created_at))+'</time>'+
            '</div>';
          }).join('');
        }
    
        aviatorBankLedgerLastLoad=Date.now();
        if(status)status.textContent='Atualizado';
      }catch(e){
        host.innerHTML='<p class="form-message">'+escapeHtml(e.message)+'</p>';
        if(status)status.textContent='Erro';
      }finally{
        aviatorBankLedgerBusy=false;
      }
    }
    
    function aviatorAdminActionLabel(action){
      const labels={
        'aviator.admin.closed':'Fechou o Aviator',
        'aviator.admin.reopened':'Reabriu o Aviator',
        'aviator.admin.bank_adjusted':'Ajustou a banca',
        'aviator.admin.risk_limit_changed':'Alterou limite de risco',
        'aviator.admin.one_round_test_started':'Iniciou rodada de teste',
        'aviator.round_admin_cancelled':'Cancelou rodada e reembolsou',
        'aviator.maintenance_changed':'Alterou manutenção',
        'aviator.bank_adjusted':'Ajustou a banca',
        'aviator.one_round_test_started':'Iniciou rodada de teste',
        'aviator.maintenance':'Alterou manutenção',
        'aviator.maintenance_preflight_refunded':'Resolveu manutenção/reembolso'
      };
      return labels[action]||String(action||'Ação administrativa');
    }
    
    function aviatorAuditStateText(stateObj){
      const data=stateObj&&typeof stateObj==='object'?stateObj:{};
      const parts=[];
      if(Object.hasOwn(data,'enabled'))parts.push(data.enabled?'Aviator aberto':'Aviator fechado');
      if(Object.hasOwn(data,'one_round_test'))parts.push(data.one_round_test?'teste ativo':'teste desligado');
      if(Object.hasOwn(data,'balance'))parts.push('banca '+money(data.balance)+' MZN');
      if(data.status)parts.push('estado '+String(data.status));
      if(Object.hasOwn(data,'refundedBets'))parts.push(String(data.refundedBets)+' reembolso(s)');
      return parts.join(' · ')||'—';
    }
    
    function aviatorAuditDetailText(item){
      const d=item.details||{};
      const parts=[];
      if(d.reason)parts.push('Motivo: '+d.reason);
      if(d.delta!==undefined)parts.push('Ajuste: '+money(d.delta)+' MZN');
      if(d.field==='exposure_ratio'&&d.previous!==undefined&&d.current!==undefined){
        parts.push(
          'Limite de risco: '+(Number(d.previous)*100).toFixed(0)+'% → '+
          (Number(d.current)*100).toFixed(0)+'%'
        );
      }
      if(d.refundedBets!==undefined)parts.push('Reembolsos: '+String(d.refundedBets));
      if(d.refundedTotal!==undefined)parts.push('Total devolvido: '+money(d.refundedTotal)+' MZN');
      if(d.cashoutsKept!==undefined)parts.push('Cash-outs preservados: '+String(d.cashoutsKept));
      return parts.join(' · ');
    }
    
    async function refreshAviatorAudit(force=false){
      const wrap=$('aviatorAuditWrap');
      const host=$('aviatorAuditList');
      const status=$('aviatorAuditStatus');
      if(!wrap||!host||!state.token)return;
      if(!wrap.open&&!force)return;
      if(aviatorAuditBusy)return;
      if(!force&&Date.now()-aviatorAuditLastLoad<5000)return;
    
      aviatorAuditBusy=true;
      if(status)status.textContent='A carregar…';
    
      try{
        const rows=await rpc('jl_aviator_admin_audit_history',{
          p_token:state.token,
          p_limit:40
        });
        const items=Array.isArray(rows)?rows:[];
        if(!items.length){
          host.innerHTML='<p class="muted">Ainda não há ações administrativas registadas.</p>';
        }else{
          host.innerHTML=items.map(item=>{
            const actor=escapeHtml(item.actor_name||'Administrador');
            const role=escapeHtml(item.actor_role||'admin');
            const target=item.target_type==='aviator_round'&&item.target_id
              ?'Rodada #'+escapeHtml(item.target_id)
              :item.target_type==='aviator_bank'
                ?'Banca do Aviator'
                :item.target_type==='aviator_settings'
                  ?'Configuração do Aviator'
                  :escapeHtml(item.target_type||'Aviator');
            const detail=aviatorAuditDetailText(item);
            return '<details class="aviator-audit-item">'+
              '<summary><span>'+escapeHtml(aviatorAdminActionLabel(item.action))+'</span>'+
              '<small>'+actor+' · '+role+' · '+dateTime(item.created_at)+'</small></summary>'+
              '<div class="aviator-audit-body">'+
                '<p><strong>Alvo:</strong> '+target+'</p>'+
                '<p><strong>Antes:</strong> '+escapeHtml(aviatorAuditStateText(item.before_state))+'</p>'+
                '<p><strong>Depois:</strong> '+escapeHtml(aviatorAuditStateText(item.after_state))+'</p>'+
                (detail?'<p>'+escapeHtml(detail)+'</p>':'')+
              '</div>'+
            '</details>';
          }).join('');
        }
        aviatorAuditLastLoad=Date.now();
        if(status)status.textContent='Atualizado';
      }catch(e){
        host.innerHTML='<p class="form-message">'+escapeHtml(e.message)+'</p>';
        if(status)status.textContent='Erro';
      }finally{
        aviatorAuditBusy=false;
      }
    }
    
    async function refreshAviatorAdmin(){
      if(!state.token||!$('aviatorAdmin')) return;
      try{
        const [d,engineTest]=await Promise.all([
          rpc('jl_aviator_admin_state',{p_token:state.token}),
          rpc('jl_aviator_admin_engine_test_state',{p_token:state.token})
        ]),r=d.round||{};
        const roundExposure=d.exposure||{};
        const house=d.house||{};
        const bankBalance=Number(d.bank?.balance)||0,exposure=Number(d.bank?.exposure_ratio)||0.5;
        $('aviatorBankBalance').textContent=money(bankBalance);
        $('aviatorRound').textContent=r.id?'#'+r.id:'—'; $('aviatorStatus').textContent=r.status||'—';
        $('aviatorCeiling').textContent=r.financial_ceiling?Number(r.financial_ceiling).toFixed(2)+'×':'—';
        $('aviatorReserve').textContent=money(r.risk_reserve);
        $('aviatorStaked').textContent=money(roundExposure.total_staked??d.stake_sum);
        $('aviatorPotentialPayout').textContent=money(roundExposure.potential_payment);
        $('aviatorPlayers').textContent=String(Number(roundExposure.players)||0);
        $('aviatorCashouts').textContent=String(Number(roundExposure.cashouts)||0);
        $('aviatorCashoutsPaid').textContent=money(roundExposure.cashout_paid)+' MZN pagos';
        $('aviatorCrash').textContent=r.crash_multiplier?Number(r.crash_multiplier).toFixed(2)+'×':'—';
    
        const houseIndicator=$('aviatorHouseIndicator');
        const houseState=String(house.status||'HEALTHY').toUpperCase();
        const houseLabels={
          HEALTHY:'Saudável',
          ATTENTION:'Atenção',
          CRITICAL:'Crítico'
        };
        if(houseIndicator)houseIndicator.dataset.state=houseState;
        $('aviatorHouseStatus').textContent=houseLabels[houseState]||houseState;
        $('aviatorHouseBank').textContent=money(house.bank_balance)+' MZN';
        $('aviatorHouseLiability').textContent=money(house.active_liability)+' MZN';
        $('aviatorHouseAvailable').textContent=money(house.available_after_worst_case)+' MZN';
        $('aviatorHouseRiskUsage').textContent=(Number(house.risk_usage_pct)||0).toFixed(2)+'%';
        $('aviatorHouseRoundResult').textContent=
          (Number(house.round_realized_result)||0)>=0
            ?'+'+money(house.round_realized_result)+' MZN'
            :money(house.round_realized_result)+' MZN';
        $('aviatorHouseUpdated').textContent='Atualizado agora';
        const referenceStake=10,referenceCeiling=1+(bankBalance*exposure/referenceStake),bankWarning=$('aviatorBankWarning');
        const readiness=$('aviatorReadiness'),referenceCeilings=$('aviatorReferenceCeilings');
        const enginePassed=engineTest?.passed===true;
        const engineFailed=Array.isArray(engineTest?.failed_checks)?engineTest.failed_checks:[];
        const engineChecks=Array.isArray(engineTest?.checks)?engineTest.checks:[];
        const enginePassedCount=engineChecks.filter(item=>item?.ok===true).length;
        const engineTotal=engineChecks.length;
        const engineStatus=$('aviatorEngineTestStatus');
        const engineDetail=$('aviatorEngineTestDetail');
        if(engineStatus){
          engineStatus.textContent=enginePassed?'TESTES OK':'TESTES NECESSÁRIOS';
        }
        if(engineDetail){
          const when=engineTest?.tested_at?dateTime(engineTest.tested_at):'Nunca executado';
          engineDetail.textContent=engineTotal
            ?enginePassedCount+'/'+engineTotal+' · '+when
            :when;
        }
        const refs=[1,5,10,50].map(stake=>({
          stake,
          ceiling:1+(bankBalance*exposure/stake)
        }));
        if(referenceCeilings){
          referenceCeilings.innerHTML=refs.map(item=>
            '<span><strong>'+item.stake+' MZN</strong> → '+item.ceiling.toFixed(2)+'×</span>'
          ).join('');
        }
        if(bankWarning){
          const showWarning=Number.isFinite(referenceCeiling)&&referenceCeiling<1.5;
          bankWarning.classList.toggle('hidden',!showWarning);
          bankWarning.textContent=showWarning
            ?'Atenção: com banca de '+money(bankBalance)+' MZN e 10 MZN apostados, o teto financeiro estimado seria '+referenceCeiling.toFixed(2)+'×. A banca baixa faz o crash financeiro ocorrer muito cedo.'
            :'';
        }
        if(readiness){
          readiness.textContent=d.one_round_test
            ?'TESTE 1 RODADA'
            :d.enabled
              ?'ABERTO'
              :enginePassed
                ?referenceCeiling<1.5
                  ?'TESTES OK · BANCA BAIXA'
                  :'TESTES OK'
                :'TESTES NECESSÁRIOS';
        }
        const draining=
          !d.enabled&&['OPEN','LOCKED','FLYING','CRASHED'].includes(String(r.status||''));
    
        const closeBtn=$('aviatorMaintenanceClose');
        if(closeBtn){
          closeBtn.disabled=!d.enabled;
          closeBtn.textContent=d.enabled?'Fechar Aviator':'Aviator fechado';
          closeBtn.classList.toggle('danger',d.enabled);
        }
    
        const reopenBtn=$('aviatorMaintenanceReopen');
        if(reopenBtn){
          reopenBtn.disabled=Boolean(d.enabled)||draining;
          reopenBtn.textContent=d.enabled
            ?'Aviator aberto'
            :draining
              ?'Aguarde a rodada atual'
              :'Reabrir Aviator';
          reopenBtn.classList.toggle('success',!d.enabled&&!draining);
        }
    
        const preflightBtn=$('aviatorEnginePreflight');
        if(preflightBtn){
          preflightBtn.disabled=Boolean(d.enabled)||draining||Boolean(d.one_round_test);
          preflightBtn.textContent=d.enabled
            ?'Feche para testar'
            :draining
              ?'Aguarde a rodada atual'
              :'Testar motor';
        }

        const oneRound=$('aviatorOneRoundTest');
        if(oneRound){
          oneRound.disabled=Boolean(d.enabled)||draining;
          oneRound.textContent=d.one_round_test?'Rodada de teste em curso':'Abrir 1 rodada de teste';
        }
    
        const cancellable=['OPEN','LOCKED','FLYING'].includes(String(r.status||''));
        const cancelBtn=$('aviatorCancelRound');
        const cancelReason=$('aviatorCancelReason');
        if(cancelBtn){
          cancelBtn.disabled=!cancellable;
          cancelBtn.dataset.roundId=cancellable&&r.id?String(r.id):'';
          cancelBtn.textContent=cancellable
            ?'Cancelar rodada e reembolsar'
            :'Sem rodada cancelável';
        }
        if(cancelReason){
          cancelReason.disabled=!cancellable;
        }
    
        if($('aviatorBankLedgerWrap')?.open){
          void refreshAviatorBankLedger(false);
        }
        if($('aviatorAuditWrap')?.open){
          void refreshAviatorAudit(false);
        }
      }catch(e){$('aviatorAdminMessage').textContent=e.message}
    }
    $('aviatorBankLedgerWrap')?.addEventListener('toggle',()=>{
      const wrap=$('aviatorBankLedgerWrap');
      const status=$('aviatorBankLedgerStatus');
      if(!wrap)return;
      if(wrap.open){
        void refreshAviatorBankLedger(true);
      }else if(status){
        status.textContent='Abrir';
      }
    });
    
    $('aviatorAuditWrap')?.addEventListener('toggle',()=>{
      const wrap=$('aviatorAuditWrap');
      const status=$('aviatorAuditStatus');
      if(!wrap)return;
      if(wrap.open){
        void refreshAviatorAudit(true);
      }else if(status){
        status.textContent='Abrir';
      }
    });
    
    async function closeAviatorFromAdmin(button=$('aviatorMaintenanceClose')){
      if(!state.token){
        $('aviatorAdminMessage').textContent='Sessão administrativa expirada. Entre novamente.';
        toast('Sessão administrativa expirada. Entre novamente.','error');
        return;
      }
    
      try{
        if(button){
          button.disabled=true;
          button.textContent='Fechando…';
        }
    
        $('aviatorAdminMessage').textContent='Fechando Aviator…';
    
        const result=await rpc('jl_aviator_admin_close',{p_token:state.token});
        const refunded=Number(result.refunded_bets)||0;
        const refundedTotal=Number(result.refunded_total)||0;
    
        $('aviatorAdminMessage').textContent=refunded>0
          ?'Aviator fechado. '+refunded+' aposta'+(refunded===1?'':'s')+
            ' reembolsada'+(refunded===1?'':'s')+
            ' automaticamente ('+money(refundedTotal)+' MZN).'
          :result.draining
            ?'Aviator fechado. A rodada atual terminará com segurança.'
            :'Aviator fechado para manutenção.';
    
        toast('Aviator fechado.','success');
        await refreshAviatorAdmin();
      }catch(e){
        const message='Falha ao fechar Aviator: '+String(e?.message||e||'Erro desconhecido.');
        $('aviatorAdminMessage').textContent=message;
        toast(message,'error');
        if(button){
          button.disabled=false;
          button.textContent='Fechar Aviator';
        }
      }
    }
    
    window.JLCloseAviator=closeAviatorFromAdmin;
    
    document.addEventListener('click',(event)=>{
      const button=event.target?.closest?.('#aviatorMaintenanceClose');
      if(!button)return;
      event.preventDefault();
      void closeAviatorFromAdmin(button);
    });
    
    $('aviatorCancelRound')?.addEventListener('click',async()=>{
      const button=$('aviatorCancelRound');
      const reasonInput=$('aviatorCancelReason');
      const reason=String(reasonInput?.value||'').trim();
      const roundId=Number(button?.dataset.roundId);
    
      if(reason.length<5){
        const message='Informe o motivo do cancelamento com pelo menos 5 caracteres.';
        $('aviatorAdminMessage').textContent=message;
        toast(message,'error');
        reasonInput?.focus();
        return;
      }
    
      if(!Number.isInteger(roundId)||roundId<1){
        const message='Não há rodada cancelável neste momento.';
        $('aviatorAdminMessage').textContent=message;
        toast(message,'error');
        await refreshAviatorAdmin();
        return;
      }
    
      try{
        button.disabled=true;
        button.textContent='Cancelando e reembolsando…';
        $('aviatorAdminMessage').textContent='Cancelando rodada #'+roundId+'…';
    
        const result=await rpc('jl_aviator_admin_cancel_round',{
          p_token:state.token,
          p_round_id:roundId,
          p_reason:reason
        });
    
        const refunded=Number(result.refunded_bets)||0;
        const refundedTotal=Number(result.refunded_total)||0;
        const cashoutsKept=Number(result.cashouts_kept)||0;
    
        $('aviatorAdminMessage').textContent=
          'Rodada #'+roundId+' cancelada. '+
          refunded+' aposta'+(refunded===1?'':'s')+' reembolsada'+(refunded===1?'':'s')+
          ' ('+money(refundedTotal)+' MZN).'+
          (cashoutsKept>0?' '+cashoutsKept+' cash-out'+(cashoutsKept===1?' preservado.':'s preservados.'):'');
        toast('Rodada cancelada e reembolsos concluídos.','success');
    
        if(reasonInput)reasonInput.value='';
        await refreshAviatorAdmin();
      }catch(e){
        const message='Falha ao cancelar rodada: '+String(e?.message||e||'Erro desconhecido.');
        $('aviatorAdminMessage').textContent=message;
        toast(message,'error');
        await refreshAviatorAdmin();
      }
    });
    
    $('aviatorEnginePreflight')?.addEventListener('click',async()=>{
      const button=$('aviatorEnginePreflight');
      try{
        if(button){
          button.disabled=true;
          button.textContent='Testando motor…';
        }
        $('aviatorAdminMessage').textContent='Executando testes automáticos do motor…';

        const result=await rpc('jl_aviator_admin_engine_preflight',{p_token:state.token});
        const passed=Number(result?.passed)||0;
        const total=Number(result?.total)||0;
        const failed=Array.isArray(result?.failed_checks)?result.failed_checks:[];

        if(result?.ok===true){
          $('aviatorAdminMessage').textContent=
            passed+'/'+total+' testes automáticos passaram. Motor certificado para tentativa de abertura.';
          toast('Testes do motor aprovados.','success');
        }else{
          $('aviatorAdminMessage').textContent=
            'Testes do motor falharam: '+(failed.length?failed.join(', '):'falha não identificada')+'.';
          toast('Testes do motor falharam.','error');
        }
      }catch(e){
        $('aviatorAdminMessage').textContent=
          'Falha ao testar motor: '+String(e?.message||e||'Erro desconhecido.');
      }finally{
        await refreshAviatorAdmin();
      }
    });

    $('aviatorMaintenanceReopen')?.addEventListener('click',async()=>{
      const button=$('aviatorMaintenanceReopen');
      try{
        const d=await rpc('jl_aviator_admin_state',{p_token:state.token});
        const r=d.round||{};
        const draining=
          !d.enabled&&['OPEN','LOCKED','FLYING','CRASHED'].includes(String(r.status||''));
    
        if(d.enabled){
          $('aviatorAdminMessage').textContent='Aviator já está aberto.';
          await refreshAviatorAdmin();
          return;
        }
    
        if(draining){
          $('aviatorAdminMessage').textContent=
            'Aguarde a rodada atual terminar antes de reabrir o Aviator.';
          await refreshAviatorAdmin();
          return;
        }
    
        const bankBalance=Number(d.bank?.balance)||0;
        const exposure=Number(d.bank?.exposure_ratio)||0.5;
        const referenceCeiling=1+(bankBalance*exposure/10);
        const lowBankWarning=referenceCeiling<1.5
          ?' Atenção: a banca atual está baixa e o teto estimado para 10 MZN é '+
            referenceCeiling.toFixed(2)+'×.'
          :'';
    
        const ok=window.confirm(
          'Reabrir Aviator agora? Novas rodadas e novas apostas voltarão a ser permitidas.'+
          lowBankWarning
        );
        if(!ok)return;
    
        if(button){
          button.disabled=true;
          button.textContent='Testando e reabrindo…';
        }

        const reopened=await rpc('jl_aviator_admin_reopen',{p_token:state.token});
        const engineTest=reopened?.engine_test||{};
        const passed=Number(engineTest?.passed)||0;
        const total=Number(engineTest?.total)||0;
        $('aviatorAdminMessage').textContent=
          'Aviator reaberto após '+passed+'/'+total+' testes automáticos do motor.';
        await refreshAviatorAdmin();
      }catch(e){
        $('aviatorAdminMessage').textContent=e.message;
        await refreshAviatorAdmin();
      }
    });
    
    $('aviatorOneRoundTest')?.addEventListener('click',async()=>{
      try{
        const d=await rpc('jl_aviator_admin_state',{p_token:state.token});
        if(d.enabled){
          throw new Error('Feche o Aviator antes de iniciar uma rodada de teste.');
        }
        const bankBalance=Number(d.bank?.balance)||0;
        const exposure=Number(d.bank?.exposure_ratio)||0.5;
        const ceiling10=1+(bankBalance*exposure/10);
        const ok=window.confirm(
          'Abrir exatamente 1 rodada real de teste? Ao terminar, o Aviator volta sozinho para manutenção. '+
          'Com 10 MZN apostados, o teto estimado atual é '+ceiling10.toFixed(2)+'×.'
        );
        if(!ok)return;
        const started=await rpc('jl_aviator_admin_start_one_round_test',{p_token:state.token});
        const engineTest=started?.engine_test||{};
        $('aviatorAdminMessage').textContent=
          'Motor aprovado em '+(Number(engineTest.passed)||0)+'/'+(Number(engineTest.total)||0)+
          ' checks. Rodada de teste armada; o Aviator voltará à manutenção após liquidá-la.';
        await refreshAviatorAdmin();
      }catch(e){$('aviatorAdminMessage').textContent=e.message}
    });
    
    $('aviatorBankAdjust')?.addEventListener('click',async()=>{
      try{
        const delta=Number($('aviatorBankDelta').value),reason=$('aviatorBankReason').value.trim();
        const requestKey=adminFinancialRequestKey('aviator-bank',{delta,reason});
        const r=await rpc('jl_aviator_admin_adjust_bank',{p_token:state.token,p_delta:delta,p_reason:reason,p_request_key:requestKey});
        clearAdminFinancialRequestKey('aviator-bank',requestKey);
        $('aviatorAdminMessage').textContent=(r.already_processed?'Ajuste já confirmado. Banca: ':'Banca atualizada: ')+money(r.balance)+' MZN';
        $('aviatorBankDelta').value='';
        $('aviatorBankReason').value='';
        await refreshAviatorAdmin();
        if($('aviatorBankLedgerWrap')?.open){
          await refreshAviatorBankLedger(true);
        }
      }catch(e){$('aviatorAdminMessage').textContent=e.message}
    });
    setInterval(()=>{if(state.token)refreshAviatorAdmin()},3000);

    return Object.freeze({
      refresh: refreshAviatorAdmin,
      refreshAudit: refreshAviatorAudit,
      refreshBankLedger: refreshAviatorBankLedger,
      close: closeAviatorFromAdmin
    });
  }

  window.JLAviatorAdmin = Object.freeze({ create });
})();
