/**
 * Auditoria/migracao de fotos dos produtos do Sabor do Chef.
 *
 * Padrao: PREVIEW. Baixa cada foto, gera WebP otimizado e guarda:
 * - original em image-migration-backup/originals/
 * - WebP em image-migration-backup/optimized/
 * - relatorio CSV em image-migration-backup/report.csv
 *
 * Somente com --apply envia o WebP ao bucket product-images e atualiza
 * products.photo_url. Nunca apaga arquivos originais do Storage.
 */
import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SERVICE_KEY) {
  throw new Error('Defina SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY nos secrets do GitHub.');
}

const APPLY = process.argv.includes('--apply');
const BUCKET = 'product-images';
const OUT = 'image-migration-backup';
const supabase = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

await fs.rm(OUT, { recursive: true, force: true });
await fs.mkdir(path.join(OUT, 'originals'), { recursive: true });
await fs.mkdir(path.join(OUT, 'optimized'), { recursive: true });

const csv = [['product_id', 'product_name', 'status', 'original_bytes', 'webp_bytes', 'reduction_percent', 'source_url', 'new_url', 'detail']];
const safe = (v) => String(v ?? '').replaceAll('"', '""');
const addRow = (row) => csv.push(row.map(v => '"' + safe(v) + '"'));
const idFile = (id, ext) => crypto.createHash('sha256').update(String(id)).digest('hex').slice(0, 20) + '.' + ext;

async function getProducts() {
  const all = [];
  const pageSize = 500;
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await supabase.from('products')
      .select('id,name,photo_url')
      .order('id')
      .range(from, from + pageSize - 1);
    if (error) throw error;
    all.push(...(data || []));
    if (!data || data.length < pageSize) break;
  }
  return all;
}

async function downloadImage(url) {
  const response = await fetch(url, { redirect: 'follow' });
  if (!response.ok) throw new Error('Falha ao baixar imagem: HTTP ' + response.status);
  const type = response.headers.get('content-type') || '';
  if (!type.startsWith('image/')) throw new Error('URL nao retornou uma imagem (' + type + ').');
  const bytes = Buffer.from(await response.arrayBuffer());
  if (!bytes.length) throw new Error('Arquivo de imagem vazio.');
  return bytes;
}

async function processProduct(product) {
  const url = product.photo_url;
  if (!url) {
    addRow([product.id, product.name, 'sem_foto', 0, 0, '', '', '', 'Produto sem foto']);
    return;
  }
  try {
    const original = await downloadImage(url);
    const metadata = await sharp(original, { failOn: 'error' }).metadata();
    if (!metadata.width || !metadata.height) throw new Error('Imagem sem dimensoes validas.');
    const optimized = await sharp(original, { failOn: 'error' })
      .rotate()
      .resize({ width: 1600, height: 1600, fit: 'inside', withoutEnlargement: true })
      .webp({ quality: 82, effort: 5 })
      .toBuffer();

    const originalName = idFile(product.id, 'original');
    const optimizedName = idFile(product.id, 'webp');
    await fs.writeFile(path.join(OUT, 'originals', originalName), original);
    await fs.writeFile(path.join(OUT, 'optimized', optimizedName), optimized);

    const reduction = original.length ? (1 - optimized.length / original.length) * 100 : 0;
    let newUrl = '';
    let status = 'preview_pronto';

    if (APPLY) {
      const storagePath = 'migrados/' + crypto.randomUUID() + '.webp';
      const { error: uploadError } = await supabase.storage.from(BUCKET).upload(storagePath, optimized, {
        contentType: 'image/webp',
        cacheControl: '31536000',
        upsert: false
      });
      if (uploadError) throw new Error('Upload falhou: ' + uploadError.message);
      newUrl = supabase.storage.from(BUCKET).getPublicUrl(storagePath).data.publicUrl;

      const { error: updateError } = await supabase.from('products')
        .update({ photo_url: newUrl })
        .eq('id', product.id);
      if (updateError) {
        // O arquivo novo fica preservado para recuperacao; a referencia antiga nao e apagada.
        throw new Error('Foto enviada, mas photo_url nao foi atualizado: ' + updateError.message);
      }
      status = 'aplicado';
    }

    addRow([
      product.id, product.name, status, original.length, optimized.length,
      reduction.toFixed(1), url, newUrl,
      metadata.width + 'x' + metadata.height + ' -> WebP'
    ]);
    console.log(status.toUpperCase() + ': ' + product.name + ' (' + original.length + ' -> ' + optimized.length + ' bytes)');
  } catch (error) {
    addRow([product.id, product.name, 'erro', '', '', '', url, '', error.message]);
    console.error('ERRO: ' + product.name + ': ' + error.message);
  }
}

const products = await getProducts();
console.log('Produtos encontrados: ' + products.length);
console.log('Modo: ' + (APPLY ? 'APLICAR ALTERACOES' : 'PREVIA - NENHUMA REFERENCIA SERA ALTERADA'));

for (const product of products) await processProduct(product);

const report = csv.map(row => row.join(',')).join('\n') + '\n';
await fs.writeFile(path.join(OUT, 'report.csv'), report, 'utf8');
const counts = csv.slice(1).reduce((acc, row) => {
  acc[row[2]] = (acc[row[2]] || 0) + 1;
  return acc;
}, {});
await fs.writeFile(path.join(OUT, 'summary.json'), JSON.stringify({
  mode: APPLY ? 'apply' : 'preview',
  products: products.length,
  counts,
  originalsPreserved: true,
  referencesChanged: APPLY
}, null, 2));
console.log('Resumo: ' + JSON.stringify(counts));
console.log('Relatorio e copias em ' + OUT);
if (counts.erro) process.exitCode = 1;
