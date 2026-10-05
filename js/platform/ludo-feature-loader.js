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
function pinViewportTop(){
const topbar=document.querySelector('.topbar');
const strip=document.getElementById('ludoStatusStrip');
const topbarHeight=topbar?Math.max(0,topbar.getBoundingClientRect().height):0;
const stripVisible=strip&&getComputedStyle(strip).display!=='none'&&!strip.classList.contains('hidden');
const stripHeight=stripVisible?Math.max(0,strip.getBoundingClientRect().height):0;
return Math.ceil(topbarHeight+stripHeight+10);
}
function fitPinnedBoard(panel,board,top){
board.style.removeProperty('width');
board.style.removeProperty('max-width');
panel.scrollTop=0;
const viewportHeight=window.visualViewport?.height||window.innerHeight||0;
if(!viewportHeight)return;
const available=Math.max(260,viewportHeight-top-12);
const boardHeight=Math.max(1,board.getBoundingClientRect().height||board.offsetHeight||1);
const chrome=Math.max(0,panel.scrollHeight-boardHeight);
const currentWidth=Math.max(1,board.getBoundingClientRect().width||board.offsetWidth||1);
const target=Math.floor(Math.min(currentWidth,available-chrome-4));
if(target>220&&target<currentWidth-2){
board.style.setProperty('width',`${target}px`,'important');
board.style.setProperty('max-width',`${target}px`,'important');
}
}
function clearPinnedViewport(panel,board){
board?.style.removeProperty('width');
board?.style.removeProperty('max-width');
panel?.style.removeProperty('scroll-margin-top');
document.documentElement.style.removeProperty('--ludo-sticky-top');
}
function showPinnedViewport(panel,board,naturalTop){
const top=pinViewportTop();
document.documentElement.style.setProperty('--ludo-sticky-top',`${top}px`);
panel.style.setProperty('scroll-margin-top',`${top+8}px`);
fitPinnedBoard(panel,board,top);
requestAnimationFrame(()=>{
panel.scrollTop=0;
const destination=Math.max(0,naturalTop-top-8);
window.scrollTo({top:destination,behavior:'auto'});
});
}
function installPinGestureGuard(){
const button=document.getElementById('pinLudo');
if(!button||button.dataset.jlPinGestureGuard==='1')return;
button.dataset.jlPinGestureGuard='1';
button.style.touchAction='pan-y';
let pointer=null;
let suppressClickUntil=0;
const now=()=>window.performance?.now?.()??Date.now();
const movedEnough=(event)=>{
if(!pointer||event.pointerId!==pointer.id)return false;
const dx=Number(event.clientX)-pointer.x;
const dy=Number(event.clientY)-pointer.y;
const scrolled=Math.abs(window.scrollY-pointer.scrollY)>4;
return Math.hypot(dx,dy)>10||scrolled;
};
document.addEventListener('pointerdown',event=>{
if(!event.target.closest?.('#pinLudo'))return;
pointer={id:event.pointerId,x:Number(event.clientX),y:Number(event.clientY),scrollY:window.scrollY,moved:false};
},{capture:true,passive:true});
document.addEventListener('pointermove',event=>{
if(pointer&&movedEnough(event))pointer.moved=true;
},{capture:true,passive:true});
document.addEventListener('pointerup',event=>{
if(!pointer||event.pointerId!==pointer.id)return;
if(pointer.moved||movedEnough(event))suppressClickUntil=now()+700;
pointer=null;
},{capture:true,passive:true});
document.addEventListener('pointercancel',event=>{
if(!pointer||event.pointerId!==pointer.id)return;
suppressClickUntil=now()+700;
pointer=null;
},{capture:true,passive:true});
button.addEventListener('click',event=>{
event.preventDefault();
event.stopImmediatePropagation();
if(now()<suppressClickUntil)return;
const panel=document.querySelector('#gamePanel>.board-panel');
const board=document.getElementById('ludoBoard');
if(!panel||!board)return;
const naturalTop=window.scrollY+panel.getBoundingClientRect().top;
const pinned=!document.body.classList.contains('ludo-pinned');
document.body.classList.toggle('ludo-pinned',pinned);
button.setAttribute('aria-pressed',pinned?'true':'false');
button.textContent=pinned?'Desafixar':'Fixar Ludo';
if(pinned)showPinnedViewport(panel,board,naturalTop);
else clearPinnedViewport(panel,board);
},true);
}
function init(){
notifications();support();recovery();account();installLobbyRecovery();installPinGestureGuard();
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