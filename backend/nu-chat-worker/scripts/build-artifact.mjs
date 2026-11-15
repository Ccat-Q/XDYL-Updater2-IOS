import {build,version as esbuildVersion} from 'esbuild';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';

// Compilation is deliberately restricted to GitHub Actions. Production receives
// this verified prebuilt artifact; no Cloudflare credential belongs in CI.
if(process.env.GITHUB_ACTIONS!=='true')throw new Error('Build Worker artifacts in GitHub Actions only');
const commit=process.env.GITHUB_SHA;
if(!/^[a-f0-9]{40}$/.test(commit??''))throw new Error('A full GitHub source revision is required');
const temp=process.env.RUNNER_TEMP;
if(!temp||!path.isAbsolute(temp))throw new Error('RUNNER_TEMP is required');
const outdir=path.join(temp,'nu-chat-worker-build');
await mkdir(outdir,{recursive:true});
const result=await build({entryPoints:['src/index.js'],bundle:true,format:'esm',platform:'browser',target:'es2022',sourcemap:true,metafile:true,outdir});
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const sourceHashes={};
for(const input of Object.keys(result.metafile.inputs).sort()){
  if(!/^src\/[a-z0-9_-]+\.js$/.test(input))throw new Error('Unexpected Worker dependency in deployable artifact');
  sourceHashes[input]=digest(await readFile(input));
}
const manifest={schema:'nu-chat-worker-artifact/1',git_sha:commit,entrypoint:'index.js',esbuild_version:esbuildVersion,bundle_sha256:digest(await readFile(path.join(outdir,'index.js'))),source_map_sha256:digest(await readFile(path.join(outdir,'index.js.map'))),source_hashes:sourceHashes};
await writeFile(path.join(outdir,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
console.log(`Built Worker artifact for ${commit.slice(0,12)} with ${Object.keys(sourceHashes).length} verified source modules`);
