(() => {
'use strict';
const FEATURES=Object.freeze({
support:{css:['./support-ui.css?v=20260922-12fix'],js:['./support-ui.js?v=20260928-1']},
recovery:{css:['./recovery-ui.css?v=20260922-13'],js:['./recovery-ui.js?v=20260928-2']},
notifications:{js:['./js/notifications/client.js?v=20260928-22']},
sessions:{js:['./js/auth/player-sessions.js?v=20260928-1']},
social:{js:['./social.js?v=20261003-5']},
policy:{js:['./js/ludo/policy.js?v=20261003-3']}
});
const state=new Map(),queue=[];
let facade=null,replaying=false;
let boardDirectionTimer=0,boardDirectionUntil=0;
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
function activeRoomRecoveryState(){
const recovery=window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__;
return recovery&&typeof recovery==='object'?recovery:null;
}
function showLobby(){
const lobby=document.getElementById('lobby');
if(!lobby)return;
lobby.classList.remove('hidden');
document.getElementById('loggedOut')?.classList.add('hidden');
document.getElementById('notificationCenter')?.classList.remove('hidden');
document.getElementById('ludoStatusStrip')?.classList.remove('hidden');
document.getElementById('boardLobby')?.classList.remove('hidden');
}
function restoreLobbyIfStranded(force=false){
if(!hasToken())return;
const lobby=document.getElementById('lobby');
const room=document.getElementById('room');
if(!lobby||!room)return;
const roomVisible=!room.classList.contains('hidden');
const lobbyVisible=!lobby.classList.contains('hidden');
if(roomVisible||lobbyVisible)return;
const recovery=activeRoomRecoveryState();
if(recovery?.activeRoomId)return;
if(!force&&recovery?.pending&&recovery?.resolved!==true)return;
showLobby();
}
function installLobbyRecovery(){
const run=()=>restoreLobbyIfStranded(false);
setTimeout(run,900);
setTimeout(()=>restoreLobbyIfStranded(true),2600);
setTimeout(()=>restoreLobbyIfStranded(true),5000);
window.addEventListener('pageshow',()=>setTimeout(()=>restoreLobbyIfStranded(true),300));
window.addEventListener('jl-ludo-active-room-recovery',run);
window.addEventListener('jl-player-session-changed',event=>{
if(event.detail?.authenticated)setTimeout(()=>restoreLobbyIfStranded(true),500);
});
document.addEventListener('visibilitychange',()=>{
if(document.visibilityState==='visible')setTimeout(()=>restoreLobbyIfStranded(true),300);
});
}
function ludoBoardDestination(){
const room=document.getElementById('room');
const game=document.getElementById('gamePanel');
const board=document.getElementById('ludoBoard');
if(!room||room.classList.contains('hidden')||room.hidden)return null;
if(!game||game.classList.contains('hidden')||game.hidden||!board||!board.childElementCount)return null;
return document.querySelector('#gamePanel>.board-panel')||board;
}
function directToLudoBoard(behavior='auto',force=false){
const target=ludoBoardDestination();
if(!target)return false;
const board=document.getElementById('ludoBoard');
const topbar=document.querySelector('.topbar')?.getBoundingClientRect().height||0;
target.style.scrollMarginTop=`${Math.ceil(topbar+8)}px`;
try{
const url=new URL(window.location.href);
const roomId=window.__JL_LUDO_RUNTIME_STATE__?.room?.room?.id
||activeRoomRecoveryState()?.activeRoomId
||document.documentElement.dataset.jlConfirmedActiveLudoRoom
||'';
if(roomId)url.searchParams.set('room',String(roomId));
url.hash='ludoBoard';
window.history.replaceState(window.history.state,'',url.toString());
}catch{window.location.hash='ludoBoard';}
const expected=topbar+8;
const rect=target.getBoundingClientRect();
if(force||Math.abs(rect.top-expected)>18)target.scrollIntoView({behavior,block:'start'});
if(board&&target!==board){
requestAnimationFrame(()=>{
const panel=document.querySelector('#gamePanel>.board-panel');
if(panel&&panel.scrollHeight>panel.clientHeight){
const offset=Math.max(0,Number(board.offsetTop)-8);
panel.scrollTo({top:offset,behavior:'auto'});
}
});
}
return true;
}
function armLudoBoardDirection(duration=2600){
boardDirectionUntil=Math.max(boardDirectionUntil,Date.now()+duration);
clearTimeout(boardDirectionTimer);
let first=true;
const tick=()=>{
const found=directToLudoBoard(first?'smooth':'auto',first);
if(found)first=false;
if(Date.now()<boardDirectionUntil)boardDirectionTimer=setTimeout(tick,120);
else boardDirectionTimer=0;
};
boardDirectionTimer=setTimeout(tick,0);
}
function installBoardDirection(){
document.addEventListener('submit',event=>{
if(!['createRoomForm','joinCodeForm'].includes(event.target?.id))return;
armLudoBoardDirection(3400);
},true);
document.addEventListener('click',event=>{
if(event.target.closest?.('#pinLudo,[data-invite-accept],[data-public-accept]'))armLudoBoardDirection(2600);
},true);
window.addEventListener('jl-ludo-authoritative-room',()=>armLudoBoardDirection(2600));
const game=document.getElementById('gamePanel');
if(game)new MutationObserver(()=>{
if(!game.classList.contains('hidden'))armLudoBoardDirection(1800);
}).observe(game,{attributes:true,attributeFilter:['class','hidden']});
}
function init(){
notifications();support();recovery();account();installLobbyRecovery();installBoardDirection();
idle('policy',350);
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