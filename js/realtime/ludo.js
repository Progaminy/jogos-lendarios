(function(root){
  'use strict';

  let client=null;
  let channel=null;
  let roomId='';
  let connected=false;
  let handlers={};
  let signalTimer=0;
  let pendingPayload=null;

  function setStatus(value){
    const next=Boolean(value);
    if(connected===next)return;
    connected=next;
    try{handlers.onStatus?.(next);}catch{}
  }

  function ensureClient(){
    if(client)return client;
    const cfg=root.JL_CONFIG||{};
    const lib=root.supabase;
    if(!lib?.createClient||!cfg.supabaseUrl||!cfg.supabaseKey)return null;
    client=lib.createClient(cfg.supabaseUrl,cfg.supabaseKey,{
      auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}
    });
    return client;
  }

  function flushSignal(){
    signalTimer=0;
    const payload=pendingPayload;
    pendingPayload=null;
    try{handlers.onSignal?.(payload);}catch{}
  }

  function queueSignal(payload){
    if(payload?.kind==='dice_rolled'){
      try{handlers.onSignal?.(payload);}catch{}
      return;
    }
    pendingPayload=payload||pendingPayload;
    if(signalTimer)return;
    signalTimer=setTimeout(flushSignal,60);
  }

  function connect(nextRoomId,options={}){
    const id=String(nextRoomId||'').trim();
    if(!id)return false;
    handlers=options||{};
    const sb=ensureClient();
    if(!sb)return false;
    if(channel&&roomId===id)return true;

    const previous=channel;
    channel=null;
    if(previous){try{void sb.removeChannel(previous);}catch{}}

    roomId=id;
    setStatus(false);
    const current=sb
      .channel(`ludo:room:${id}`,{config:{broadcast:{self:false}}})
      .on('broadcast',{event:'sync'},message=>{
        if(channel!==current)return;
        queueSignal(message?.payload||null);
      })
      .subscribe(status=>{
        if(channel!==current)return;
        if(status==='SUBSCRIBED'){setStatus(true);return;}
        if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status))setStatus(false);
      });

    channel=current;
    return true;
  }

  async function disconnect(){
    clearTimeout(signalTimer);
    signalTimer=0;
    pendingPayload=null;
    roomId='';
    setStatus(false);
    const current=channel;
    channel=null;
    if(!current||!client)return;
    try{await client.removeChannel(current);}catch{}
  }

  // Voice needs only a passive audio sink; it carries no game state.
  if(!document.getElementById('remoteAudio')){
    const sink=document.createElement('div');
    sink.id='remoteAudio';
    sink.className='remote-audio hidden';
    sink.setAttribute('aria-hidden','true');
    document.body.appendChild(sink);
  }

  root.JLLudoRealtime=Object.freeze({connect,disconnect,isConnected:()=>connected,roomId:()=>roomId});
})(typeof globalThis!=='undefined'?globalThis:this);
