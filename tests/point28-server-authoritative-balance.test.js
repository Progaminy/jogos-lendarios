const fs=require('fs');
const path=require('path');
const assert=require('assert');

const root=path.resolve(__dirname,'..');
const skip=new Set(['node_modules','.git']);

function walk(dir){
  const out=[];
  for(const entry of fs.readdirSync(dir,{withFileTypes:true})){
    if(skip.has(entry.name)) continue;
    const full=path.join(dir,entry.name);
    if(entry.isDirectory()) out.push(...walk(full));
    else if(entry.isFile()&&entry.name.endsWith('.js')&&!full.includes(path.join('tests',path.sep))) out.push(full);
  }
  return out;
}

const files=walk(root);
const forbidden=[
  /\.balance\s*(?:[+\-*/]?=|\+\+|--)/g,
  /\bbalance\s*(?:[+\-*/]?=|\+\+|--)/g,
  /player\.balance\s*[+\-*/]/g,
  /identity(?:\?|\.)?\.balance\s*[+\-*/]/g,
  /balance\s*-\s*(?:stake|amount|bet|payout)/gi
];

const violations=[];
for(const file of files){
  const source=fs.readFileSync(file,'utf8');
  for(const rule of forbidden){
    rule.lastIndex=0;
    let match;
    while((match=rule.exec(source))){
      const line=source.slice(0,match.index).split('\n').length;
      violations.push(`${path.relative(root,file)}:${line}: ${match[0]}`);
    }
  }
}

assert.deepStrictEqual(
  violations,
  [],
  'Frontend não pode alterar nem projetar saldo localmente:\n'+violations.join('\n')
);

const app=fs.readFileSync(path.join(root,'app.js'),'utf8');
const ludo=fs.readFileSync(path.join(root,'ludo.js'),'utf8');

assert.match(app,/player\.balance_confirmed===true/,'app.js deve exigir balance_confirmed');
assert.match(ludo,/i\.balance_confirmed===true/,'Ludo deve exigir balance_confirmed na identidade');
assert.match(ludo,/identity\?\.balance_confirmed===true/,'Modal de aposta do Ludo deve exigir saldo confirmado');
assert.doesNotMatch(ludo,/depois da confirmação:[^\n]*balance/i,'Ludo não pode mostrar saldo previsto');
assert.match(app,/await refresh\(true\)/,'Fluxos financeiros principais devem refrescar estado do servidor');
assert.match(ludo,/jl_ludo_commit_stake[\s\S]{0,220}await loadStatus\(true\)/,'Stake Ludo deve recarregar saldo do servidor');

console.log('point28 server-authoritative balance: ok');
