(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports){
    module.exports=api;
  }else{
    root.JLAviatorFairness=api;
  }
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';

  const VERSION='JL-AVIATOR-PF-v2';

  async function sha256Hex(text){
    const bytes=new TextEncoder().encode(String(text));
    const digest=await globalThis.crypto.subtle.digest('SHA-256',bytes);
    return Array.from(new Uint8Array(digest))
      .map(b=>b.toString(16).padStart(2,'0'))
      .join('');
  }

  function visualTarget(seedCommit){
    const commit=String(seedCommit||'').toLowerCase();
    if(!/^[0-9a-f]{64}$/.test(commit))return null;
    const n=Number.parseInt(commit.slice(0,13),16);
    const u=n/4503599627370495;
    return Math.round((5+130.7*u)*1e6)/1e6;
  }

  function nearlyEqual(a,b,places=6){
    const x=Number(a),y=Number(b);
    if(!Number.isFinite(x)||!Number.isFinite(y))return false;
    const scale=10**places;
    return Math.round(x*scale)===Math.round(y*scale);
  }

  async function verify(proof){
    if(!proof?.available)return Object.freeze({valid:false,reason:proof?.reason||'unavailable'});
    if(proof.fairness_version!==VERSION)return Object.freeze({valid:false,reason:'version'});

    const seedCommit=await sha256Hex(proof.seed||'');
    const seedCommitValid=seedCommit===String(proof.seed_commit||'').toLowerCase();

    const expectedVisual=visualTarget(proof.seed_commit);
    const visualTargetValid=nearlyEqual(expectedVisual,proof.inputs?.visual_target);

    const lockCommit=await sha256Hex(proof.lock_payload||'');
    const lockCommitValid=lockCommit===String(proof.lock_commit||'').toLowerCase();

    const visualExtension=Boolean(proof.inputs?.visual_extension);
    const locked=Number(proof.inputs?.locked_effective_target);
    const visual=Number(proof.inputs?.visual_target);
    const zero=Number(proof.inputs?.zero_exposure_at_multiplier);
    const expectedCrash=visualExtension
      ? Math.max(visual,Number.isFinite(zero)?zero:visual)
      : locked;
    const resultValid=nearlyEqual(expectedCrash,proof.result?.actual_crash_multiplier);

    return Object.freeze({
      valid:seedCommitValid&&visualTargetValid&&lockCommitValid&&resultValid,
      seedCommitValid,
      visualTargetValid,
      lockCommitValid,
      resultValid,
      expectedVisual,
      expectedCrash
    });
  }

  return Object.freeze({VERSION,sha256Hex,visualTarget,verify});
});
