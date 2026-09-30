(() => {
'use strict';
const FEATURES=Object.freeze({
support:{css:['./support-ui.css?v=20260922-12fix'],js:['./support-ui.js?v=20260928-1']},
recovery:{css:['./recovery-ui.css?v=20260922-13'],js:['./recovery-ui.js?v=20260928-2']},
notifications:{js:['./js/notifications/client.js?v=20260928-22']},
sessions:{js:['./js/auth/player-sessions.js?v=20260928-1']},
social:{js:['./social.js?v=20260929-2']}
});
const state=new Map(),queue=[];
let facade=null,replaying=false;
const absolute=(url)=>new URL(url,document.baseURI).href;
function loaded(kind,url){
const target=absolute(url);
const selector=kind==='style'?'link[rel="stylesheet"][href]':'script[src]';
return [...document.querySelectorAll(selector)].some(node=>
absolute(node.getAttribute(kind==='style'?'href':'src'))===target
);
}
function style(url){
if(loaded('style',url))return Promise.resolve();
return new Promise((resolve,reject)=>{
const el=document.createElement('link');
el.rel='stylesheet';el.href=url;el.dataset.jlLazyAsset='1';
el.onload=resolve;el.onerror=()=>reject(new Error('Falha ao carregar estilo.'));
document.head.appendChild(el);
});
}
function script(url){
if(loaded('script',url))return Promise.resolve();
return new Promise((resolve,reject)=>{
const el=document.createElement('script');
el.src=url;el.async=true;el.dataset.jlLazyAsset='1';
el.onload=resolve;el.onerror=()=>reject(new Error('Falha ao carregar módulo.'));
document.head.appendChild(el);
});
}
function isLoaded(name){return state.get(name)?.status==='loaded';}
function flush(){
const api=window.JLNotifications;
if(!api||api===facade)return;
while(queue.length){
const [method,args]=queue.shift();
try{api[method]?.(...args);}catch{}
}
}
function load(name){
const current=state.get(name);
if(current?.promise)return current.promise;
const spec=FEATURES[name];
if(!spec)return Promise.reject(new Error('Módulo desconhecido.'));
const entry={status:'loading',promise:null};
entry.promise=Promise.all([
...(spec.css||[]).map(style),
...(spec.js||[]).map(script)
]).then(()=>{
entry.status='loaded';
if(name==='notifications')flush();
return true;
}).catch(error=>{state.delete(name);throw error;});
state.set(name,entry);
return entry.promise;
}
function idle(name,timeout=1000,condition=null){
const run=()=>{if(!condition||condition())load(name).catch(()=>{});};
if('requestIdleCallback'in window)window.requestIdleCallback(run,{timeout});
else setTimeout(run,Math.min(timeout,700));
}
function hasToken(){
try{return Boolean(window.JLSession?.getPlayerToken?.()||localStorage.getItem('jl_player_token'));}
catch{return false;}
}
function notifications(){
if(window.JLNotifications)return;
const call=(method)=>(...args)=>{
queue.push([method,args]);
load('notifications').catch(()=>{});
};
const setActive=(value)=>{
if(!value){queue.length=0;return;}
queue.push(['setActive',[true]]);
load('notifications').catch(()=>{});
};
facade=Object.freeze({
push:call('push'),markRead:call('markRead'),markAllRead:call('markAllRead'),
clearAll:call('clearAll'),setActive,refresh:call('refresh'),sync:call('sync')
});
window.JLNotifications=facade;
}
function support(){
document.addEventListener('click',async event=>{
const trigger=event.target.closest?.('[data-open-support]');
if(!trigger||replaying||isLoaded('support'))return;
event.preventDefault();event.stopImmediatePropagation();
try{await load('support');replaying=true;trigger.click();}
catch{}finally{replaying=false;}
},true);
}
function recovery(){
const modal=document.getElementById('authModal');
if(!modal)return;
const check=()=>{if(!modal.classList.contains('hidden'))load('recovery').catch(()=>{});};
new MutationObserver(check).observe(modal,{attributes:true,attributeFilter:['class']});
check();
}
function account(){
const warm=event=>{
if(!event.target.closest?.('#accountButton')||!hasToken())return;
load('sessions').catch(()=>{});
};
document.addEventListener('pointerover',warm,{passive:true});
document.addEventListener('focusin',warm);
document.addEventListener('click',warm);
}
function authenticated(){
idle('notifications',700,hasToken);
idle('social',1200,hasToken);
}
function init(){
notifications();support();recovery();account();
if(hasToken())authenticated();
window.addEventListener('jl-player-session-changed',event=>{
if(event.detail?.authenticated)authenticated();
else queue.length=0;
});
}
window.JLFeatureLoader=Object.freeze({load,idle,isLoaded});
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init,{once:true});
else init();
})();
