(function(root){
  'use strict';

  let client=null;
  let channel=null;
  let connected=false;

  function setStatus(value,callback){
    const next=Boolean(value);
    if(connected===next)return;
    connected=next;
    try{callback?.(next);}catch(_){}
  }

  function ensureClient(){
    if(client)return client;
    const cfg=root.JL_CONFIG||{};
    const lib=root.supabase;
    if(!lib?.createClient||!cfg.supabaseUrl||!cfg.supabaseKey)return null;

    client=lib.createClient(cfg.supabaseUrl,cfg.supabaseKey,{
      auth:{
        persistSession:false,
        autoRefreshToken:false,
        detectSessionInUrl:false
      }
    });

    return client;
  }

  function connect(options={}){
    const sb=ensureClient();
    if(!sb)return false;
    if(channel)return true;

    channel=sb
      .channel('aviator:round',{
        config:{
          broadcast:{self:false}
        }
      })
      .on('broadcast',{event:'state'},(message)=>{
        const payload=message?.payload||null;
        if(payload)options.onState?.(payload);
      })
      .subscribe((status)=>{
        if(status==='SUBSCRIBED'){
          setStatus(true,options.onStatus);
          return;
        }
        if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status)){
          setStatus(false,options.onStatus);
        }
      });

    return true;
  }

  async function disconnect(){
    const current=channel;
    channel=null;
    connected=false;
    if(!current||!client)return;
    try{await client.removeChannel(current);}catch(_){}
  }

  root.JLAviatorRealtime=Object.freeze({
    connect,
    disconnect,
    isConnected:()=>connected
  });
})(typeof globalThis!=='undefined'?globalThis:this);
