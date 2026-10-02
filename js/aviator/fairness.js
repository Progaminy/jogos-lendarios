(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports){
    module.exports=api;
  }else{
    root.JLAviatorFairness=api;
  }
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';

  const VERSION_V2='JL-AVIATOR-PF-v2';
  const VERSION_V3='JL-AVIATOR-PF-v3';
  const VERSION=VERSION_V3;

  async function sha256Hex(text){
    const bytes=new TextEncoder().encode(String(text));
    const digest=await globalThis.crypto.subtle.digest('SHA-256',bytes);
    return Array.from(new Uint8Array(digest))
      .map(b=>b.toString(16).padStart(2,'0'))
      .join('');
  }

  function visualTarget(seedCommit,version=VERSION){
    const commit=String(seedCommit||'').toLowerCase();
    if(!/^[0-9a-f]{64}$/.test(commit))return null;

    const n=BigInt('0x'+commit.slice(0,13));
    const den=4503599627370495n;

    if(version===VERSION_V2){
      // Replica round(5 + 130.7*u, 6) das rodadas historicas.
      const variableScaled=(130700000n*n + den/2n)/den;
      const targetScaled=5000000n+variableScaled;
      return Number(targetScaled)/1e6;
    }

    if(version===VERSION_V3){
      // Novas rodadas: round(10 + 490*u, 6), intervalo 10x..500x.
      const variableScaled=(490000000n*n + den/2n)/den;
      const targetScaled=10000000n+variableScaled;
      return Number(targetScaled)/1e6;
    }

    return null;
  }

  function nearlyEqual(a,b,places=6){
    const x=Number(a),y=Number(b);
    if(!Number.isFinite(x)||!Number.isFinite(y))return false;
    const scale=10**places;
    return Math.round(x*scale)===Math.round(y*scale);
  }

  async function verify(proof){
    if(!proof?.available)return Object.freeze({valid:false,reason:proof?.reason||'unavailable'});

    const version=String(proof.fairness_version||'');
    if(version!==VERSION_V2&&version!==VERSION_V3){
      return Object.freeze({valid:false,reason:'version'});
    }

    const seedCommit=await sha256Hex(proof.seed||'');
    const seedCommitValid=seedCommit===String(proof.seed_commit||'').toLowerCase();

    const expectedVisual=visualTarget(proof.seed_commit,version);
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
      version,
      seedCommitValid,
      visualTargetValid,
      lockCommitValid,
      resultValid,
      expectedVisual,
      expectedCrash
    });
  }

  return Object.freeze({
    VERSION,
    VERSION_V2,
    VERSION_V3,
    sha256Hex,
    visualTarget,
    verify
  });
});
