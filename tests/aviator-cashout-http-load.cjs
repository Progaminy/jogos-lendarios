#!/usr/bin/env node
'use strict';

const fs=require('node:fs');
const http=require('node:http');
const https=require('node:https');
const {performance}=require('node:perf_hooks');

const jobsPath=process.argv[2];
const base=String(process.env.AVIATOR_LOAD_API_URL||'').replace(/\/$/,'');
const anon=String(process.env.AVIATOR_LOAD_ANON_KEY||'');
const maxSockets=Math.max(1,Number(process.env.AVIATOR_LOAD_PARALLEL)||100);

if(!jobsPath||!base||!anon){
  console.error('Uso: AVIATOR_LOAD_API_URL, AVIATOR_LOAD_ANON_KEY e ficheiro TSV são obrigatórios.');
  process.exit(2);
}

const jobs=fs.readFileSync(jobsPath,'utf8')
  .split(/\r?\n/)
  .filter(Boolean)
  .map(line=>{
    const [token,betId]=line.split('\t');
    return {token,betId:Number(betId)};
  });

const target=new URL(base+'/rest/v1/rpc/jl_aviator_cashout');
const transport=target.protocol==='https:'?https:http;
const agent=target.protocol==='https:'
  ?new https.Agent({keepAlive:true,maxSockets})
  :new http.Agent({keepAlive:true,maxSockets});

function percentile(values,p){
  if(!values.length)return 0;
  const sorted=[...values].sort((a,b)=>a-b);
  const idx=Math.min(sorted.length-1,Math.max(0,Math.ceil(p*sorted.length)-1));
  return sorted[idx];
}

function request(job){
  const body=JSON.stringify({p_token:job.token,p_bet_id:job.betId});
  const started=performance.now();

  return new Promise(resolve=>{
    const req=transport.request(target,{
      method:'POST',
      agent,
      headers:{
        'apikey':anon,
        'authorization':'Bearer '+anon,
        'content-type':'application/json',
        'content-length':Buffer.byteLength(body)
      }
    },res=>{
      let raw='';
      res.setEncoding('utf8');
      res.on('data',chunk=>{raw+=chunk});
      res.on('end',()=>{
        const duration=performance.now()-started;
        let payload=null;
        try{payload=JSON.parse(raw)}catch(_){}
        resolve({
          ok:res.statusCode>=200&&res.statusCode<300&&payload?.ok===true,
          status:res.statusCode,
          duration,
          payload,
          raw:raw.slice(0,500),
          betId:job.betId
        });
      });
    });

    req.setTimeout(60000,()=>{
      req.destroy(new Error('HTTP_TIMEOUT'));
    });

    req.on('error',error=>{
      resolve({
        ok:false,
        status:0,
        duration:performance.now()-started,
        error:String(error?.message||error),
        betId:job.betId
      });
    });

    req.end(body);
  });
}

(async()=>{
  const started=performance.now();

  // Todas as promessas são criadas na mesma virada do event loop:
  // chegada simultânea no cliente; o pool HTTP/DB decide a pressão real.
  const results=await Promise.all(jobs.map(request));
  const elapsed=performance.now()-started;
  agent.destroy();

  const failures=results.filter(r=>!r.ok);
  const latencies=results.map(r=>r.duration);
  const report={
    players:jobs.length,
    max_sockets:maxSockets,
    duration_ms:Math.round(elapsed),
    cashouts_per_second:Number((jobs.length/(Math.max(elapsed,1)/1000)).toFixed(2)),
    latency_ms:{
      p50:Math.round(percentile(latencies,.50)),
      p95:Math.round(percentile(latencies,.95)),
      p99:Math.round(percentile(latencies,.99)),
      max:Math.round(Math.max(0,...latencies))
    },
    successes:jobs.length-failures.length,
    failures:failures.length
  };

  console.log(JSON.stringify(report));

  if(failures.length){
    console.error('Primeiras falhas:',JSON.stringify(failures.slice(0,10)));
    process.exit(1);
  }
})().catch(error=>{
  console.error(error);
  process.exit(1);
});
