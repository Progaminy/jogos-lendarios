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
const pinState={active:false,scrollY:0,refreshTimer:0};
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
function installPinnedViewportStyle(){
if(document.getElementById('jl-ludo-static-pin-style'))return;
const style=document.createElement('style');
style.id='jl-ludo-static-pin-style';
style.textContent=`
html.jl-ludo-pin-locked,
html.jl-ludo-pin-locked body{
  overflow:hidden!important;
  overscroll-behavior:none!important;
}
html body.ludo-pinned #gamePanel>.board-panel{
  position:fixed!important;
  top:var(--jl-ludo-pin-top,160px)!important;
  left:50%!important;
  right:auto!important;
  bottom:auto!important;
  inset:auto!important;
  transform:translateX(-50%)!important;
  width:min(760px,calc(100vw - 16px))!important;
  max-width:calc(100vw - 16px)!important;
  max-height:calc(100dvh - var(--jl-ludo-pin-top,160px) - 10px)!important;
  margin:0!important;
  overflow:hidden!important;
  overscroll-behavior:contain!important;
  z-index:110!important;
}
html body.ludo-pinned #gamePanel{
  overflow:visible!important;
}
html body.ludo-pinned #ludoBoard{
  position:relative!important;
  z-index:1!important;
  margin-top:10px!important;
  margin-bottom:10px!important;
}
html body.ludo-pinned .pin-ludo-button{
  position:relative!important;
  bottom:auto!important;
  z-index:4!important;
}
@media(max-width:600px){
  html body.ludo-pinned #gamePanel>.board-panel{
    width:calc(100vw - 16px)!important;
    max-width:calc(100vw - 16px)!important;
    padding:10px!important;
  }
}
`;
document.head.appendChild(style);
}
function pinViewportTop(){
const topbar=document.querySelector('.topbar');
const strip=document.getElementById('ludoStatusStrip');
const topbarBottom=topbar?Math.max(0,topbar.getBoundingClientRect().bottom):0;
const stripVisible=strip&&getComputedStyle(strip).display!=='none'&&!strip.classList.contains('hidden');
const stripBottom=stripVisible?Math.max(0,strip.getBoundingClientRect().bottom):0;
return Math.ceil(Math.max(topbarBottom,stripBottom)+8);
}
function fitPinnedBoard(panel,board){
if(!pinState.active)return;
board.style.removeProperty('width');
board.style.removeProperty('max-width');
panel.scrollTop=0;
const viewportHeight=window.visualViewport?.height||window.innerHeight||0;
const top=pinViewportTop();
if(!viewportHeight)return;
document.documentElement.style.setProperty('--jl-ludo-pin-top',`${top}px`);
const available=Math.max(240,viewportHeight-top-10);
const panelWidth=Math.max(1,panel.clientWidth||panel.getBoundingClientRect().width||1);
const boardRect=board.getBoundingClientRect();
const boardHeight=Math.max(1,boardRect.height||board.offsetHeight||1);
const naturalWidth=Math.max(1,Math.min(boardRect.width||board.offsetWidth||1,panelWidth-20));
const chrome=Math.max(0,panel.scrollHeight-boardHeight);
const target=Math.floor(Math.min(naturalWidth,available-chrome-4));
if(target>180&&target<naturalWidth-1){
board.style.setProperty('width',`${target}px`,'important');
board.style.setProperty('max-width',`${target}px`,'important');
}
}
function refreshPinnedViewport(){
if(!pinState.active)return;
clearTimeout(pinState.refreshTimer);
pinState.refreshTimer=setTimeout(()=>{
const panel=document.querySelector('#gamePanel>.board-panel');
const board=document.getElementById('ludoBoard');
if(!panel||!board)return;
fitPinnedBoard(panel,board);
},0);
}
function releasePinnedViewport({restore=true}={}){
const panel=document.querySelector('#gamePanel>.board-panel');
const board=document.getElementById('ludoBoard');
const button=document.getElementById('pinLudo');
const restoreY=pinState.scrollY;
pinState.active=false;
clearTimeout(pinState.refreshTimer);
pinState.refreshTimer=0;
document.documentElement.classList.remove('jl-ludo-pin-locked');
document.body.classList.remove('ludo-pinned');
document.documentElement.style.removeProperty('--jl-ludo-pin-top');
board?.style.removeProperty('width');
board?.style.removeProperty('max-width');
panel?.style.removeProperty('scroll-margin-top');
if(button){
button.setAttribute('aria-pressed','false');
button.textContent='Fixar Ludo';
}
if(restore&&Number.isFinite(restoreY))requestAnimationFrame(()=>window.scrollTo({top:restoreY,behavior:'auto'}));
}
function activatePinnedViewport(panel,board,button){
pinState.scrollY=window.scrollY;
pinState.active=true;
document.body.classList.add('ludo-pinned');
document.documentElement.classList.add('jl-ludo-pin-locked');
button.setAttribute('aria-pressed','true');
button.textContent='Desafixar';
fitPinnedBoard(panel,board);
requestAnimationFrame(()=>fitPinnedBoard(panel,board));
}
function installPinGestureGuard(){
const button=document.getElementById('pinLudo');
if(!button||button.dataset.jlPinGestureGuard==='1')return;
installPinnedViewportStyle();
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
if(pinState.active||document.body.classList.contains('ludo-pinned'))releasePinnedViewport();
else activatePinnedViewport(panel,board,button);
},true);
new MutationObserver(()=>{
if(pinState.active&&!document.body.classList.contains('ludo-pinned'))releasePinnedViewport({restore:false});
}).observe(document.body,{attributes:true,attributeFilter:['class']});
window.addEventListener('resize',refreshPinnedViewport,{passive:true});
window.visualViewport?.addEventListener('resize',refreshPinnedViewport,{passive:true});
window.JLLudoPinViewport=Object.freeze({
release:()=>releasePinnedViewport({restore:false}),
isPinned:()=>pinState.active
});
}
function init(){
notifications();support();recovery();account();installLobbyRecovery();installPinGestureGuard();
idle('policy',350);
if(hasToken())authenticated();
window.addEventListener('jl-player-session-changed',event=>{
if(event.detail?.authenticated)authenticated();
else{
queue.length=0;
if(pinState.active)releasePinnedViewport({restore:false});
}
});
}
window.JLFeatureLoader=Object.freeze({load,idle,isLoaded});
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init,{once:true});
else init();
})();