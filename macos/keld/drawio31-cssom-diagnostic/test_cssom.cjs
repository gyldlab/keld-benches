'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const crypto=require('node:crypto');
const impl='mxSvgCanvas2D.prototype.setCssText=function(a,b){null!=a&&"function"===typeof a.setAttribute&&(null!=a.style?a.style.cssText=b:a.setAttribute("style",b))}';
const ctx={};require('node:vm').runInNewContext('function mxSvgCanvas2D() {}\n'+impl,ctx);
const setter=(x,y)=>ctx.mxSvgCanvas2D.prototype.setCssText(x,y);
let calls=0;const elem={style:{cssText:'initial'},setAttribute:()=>{calls++}};
setter(elem,'width:220px;height:100px');assert.equal(elem.style.cssText,'width:220px;height:100px');assert.equal(calls,0);
setter(elem,'width:42px');assert.equal(elem.style.cssText,'width:42px');
let fallback=[];setter({style:null,setAttribute:(...args)=>fallback.push(args)},'width:220px');assert.deepEqual(fallback,[['style','width:220px']]);
const blocked={style:{cssText:'unchanged'}};setter(blocked,'width:10px');assert.equal(blocked.style.cssText,'unchanged');
setter(null,'width:22px');setter({},'width:22px');
if (process.argv[2]) {
 const bytes=fs.readFileSync(process.argv[2]);
 assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),'744455ebd2c9f63db3fb9443201577f6465d99507cdcf8f61fe1a34222f5c13d');
 assert.equal(bytes.toString('utf8').split(impl).length-1,1);
}
console.log('PASS: CSSOM branch, reset, fallback, default-deny guard, null, pinned minified bundle');
