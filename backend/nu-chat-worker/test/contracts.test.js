import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {routes} from '../src/index.js';

test('every implemented route/method has a classified API contract, and every documented route exists',()=>{
  const operations=[];
  for(const name of ['CHAT_V1.md','CHAT_V2_PROPOSAL.md','CHAT_V2_EXTENSIONS.md','ANDROID_INTEROP.md']){
    const doc=readFileSync(new URL(`../../../docs/api/${name}`,import.meta.url),'utf8');
    for(const m of doc.matchAll(/^### (GET|POST|PUT|PATCH|DELETE) (\S+)\s*$/gm)){
      if(m[2]==='/push')continue; // outgoing official Bark request, not our route
      const path=m[2].replace(/\{([^}]+)\}/g,(_,key)=>key==='index'?'0':key==='username'?'alice':key==='subject'?'account:1':'00000000-0000-4000-8000-000000000001');
      assert.ok(routes.some(([pattern,methods])=>pattern.test(path)&&methods.includes(m[1])),`unimplemented contract ${m[1]} ${m[2]}`);
      operations.push({method:m[1],path});
    }
  }
  for(const [pattern,methods]of routes)for(const method of methods){
    assert.ok(operations.some(o=>o.method===method&&pattern.test(o.path)),`undocumented implementation ${method} ${pattern}`);
  }
});
