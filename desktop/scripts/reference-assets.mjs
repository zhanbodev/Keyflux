// Static extraction only. Never import, eval or execute NuPhy website code.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const manifest = JSON.parse(await readFile(new URL('../reference-assets.json', import.meta.url)));
const destination = new URL('../public/reference/', import.meta.url);
await mkdir(destination, { recursive: true });
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const downloads = new Map();
for (const asset of manifest.assets) {
  const target = new URL(asset.file, destination);
  try {
    if (hash(await readFile(target)) === asset.sha256) continue;
  } catch {}
  if (!downloads.has(asset.url))
    downloads.set(
      asset.url,
      fetch(asset.url, { signal: AbortSignal.timeout(30000) }).then(async (response) => {
        if (!response.ok) throw new Error(`Asset HTTP ${response.status}`);
        return Buffer.from(await response.arrayBuffer());
      }),
    );
  let bytes = await downloads.get(asset.url);
  if (asset.symbol) {
    const pattern = new RegExp(
      `id:"${asset.symbol}",use:.*?viewBox:"([^"]+)",content:'((?:\\\\.|[^'\\\\])*)'`,
    );
    const match = bytes.toString('utf8').match(pattern);
    if (!match || match[2].includes('\\'))
      throw new Error(`Unsupported sprite literal: ${asset.symbol}`);
    bytes = Buffer.from(
      match[2]
        .replace(/ id="[^"]+"/, '')
        .replace('<symbol', '<svg')
        .replace('</symbol>', '</svg>')
        .replaceAll('currentColor', '#454545'),
    );
  }
  if (hash(bytes) !== asset.sha256)
    throw new Error(
      `Reference asset changed: ${asset.file}. Review source before updating the manifest.`,
    );
  await writeFile(target, bytes);
}
console.log(
  'NuPhy reference assets verified (local development cache; see reference-assets.json).',
);
