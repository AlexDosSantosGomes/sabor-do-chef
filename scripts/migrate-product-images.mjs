import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';
import fs from 'node:fs/promises';
import path from 'node:path';

const APPLY = process.argv.includes('--apply');
const MAX_SIDE = 480;
const QUALITY = 78;
const BUCKET = 'product-images';
const OUT = path.resolve('image-migration-backup');
const stamp = new Date().toISOString().replace(/[:.]/g, '-');

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) throw new Error('Configure SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY nos secrets do GitHub.');
const supabase = createClient(url, key, { auth: { persistSession: false } });

await fs.mkdir(path.join(OUT, 'originals'), { recursive: true });
await fs.mkdir(path.join(OUT, 'optimized'), { recursive: true });

function storagePath(photoUrl) {
  const marker = `/storage/v1/object/public/${BUCKET}/`;
  const i = photoUrl.indexOf(marker);
  if (i < 0) throw new Error('URL não pertence ao bucket esperado: ' + photoUrl);
  return decodeURIComponent(photoUrl.slice(i + marker.length).split('?')[0]);
}

const { data: products, error } = await supabase
  .from('products').select('id,name,photo_url').not('photo_url', 'is', null).order('name');
if (error) throw error;

const manifest = [];
for (const product of products ?? []) {
  const oldPath = storagePath(product.photo_url);
  const { data: original, error: downloadError } = await supabase.storage.from(BUCKET).download(oldPath);
  if (downloadError) throw new Error(`Falha ao baixar ${product.name}: ${downloadError.message}`);
  const input = Buffer.from(await original.arrayBuffer());
  const output = await sharp(input).rotate().resize({
    width: MAX_SIDE, height: MAX_SIDE, fit: 'inside', withoutEnlargement: true
  }).webp({ quality: QUALITY }).toBuffer();

  const safeId = String(product.id).replace(/[^a-zA-Z0-9-]/g, '');
  const originalFile = path.join(OUT, 'originals', `${safeId}.original`);
  const optimizedFile = path.join(OUT, 'optimized', `${safeId}.webp`);
  await fs.writeFile(originalFile, input);
  await fs.writeFile(optimizedFile, output);

  const newPath = `produtos/otimizado-${safeId}-${stamp}.webp`;
  let newUrl = null;
  if (APPLY) {
    const { error: uploadError } = await supabase.storage.from(BUCKET).upload(newPath, output, {
      contentType: 'image/webp', cacheControl: '31536000', upsert: false
    });
    if (uploadError) throw new Error(`Falha ao enviar ${product.name}: ${uploadError.message}`);
    const { data: publicData } = supabase.storage.from(BUCKET).getPublicUrl(newPath);
    newUrl = publicData.publicUrl;

    const { data: updated, error: updateError } = await supabase.from('products')
      .update({ photo_url: newUrl }).eq('id', product.id).eq('photo_url', product.photo_url)
      .select('id').maybeSingle();
    if (updateError || !updated) {
      throw new Error(`Foto enviada, mas não foi possível confirmar a atualização de ${product.name}. Não apague o original.`);
    }
  }

  manifest.push({
    id: product.id, name: product.name, oldPath, oldUrl: product.photo_url,
    newPath: APPLY ? newPath : null, newUrl, originalBytes: input.length,
    optimizedBytes: output.length, reductionPercent: Math.round((1 - output.length / input.length) * 100),
    originalBackup: `originals/${safeId}.original`, optimizedPreview: `optimized/${safeId}.webp`,
    applied: APPLY
  });
  console.log(`${APPLY ? 'ATUALIZADO' : 'PRÉVIA'}: ${product.name} — ${input.length} -> ${output.length} bytes`);
}

await fs.writeFile(path.join(OUT, 'manifest.json'), JSON.stringify({
  generatedAt: new Date().toISOString(), mode: APPLY ? 'apply' : 'preview',
  note: 'Os arquivos originais no Supabase NÃO foram apagados.', items: manifest
}, null, 2));
console.log(`Concluído: ${manifest.length} fotos. Originais preservados no Supabase.`);
