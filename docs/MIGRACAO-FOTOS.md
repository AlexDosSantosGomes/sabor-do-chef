# Migração segura das fotos do Sabor do Chef

Este fluxo é manual e começa em modo **preview**. Ele:
- baixa as fotos atuais do bucket `product-images`;
- cria WebP com lado maior limitado a 480 px e qualidade 78;
- coloca originais e versões otimizadas em um artefato para backup/conferência;
- no modo `apply`, envia novos arquivos com nomes novos e atualiza `products.photo_url`;
- **nunca apaga os arquivos originais do Supabase**.

## Preparação única
No GitHub, em Settings → Secrets and variables → Actions, crie:
- `SUPABASE_URL`: URL do projeto Sabor do Chef;
- `SUPABASE_SERVICE_ROLE_KEY`: chave service_role/secret do projeto. Mantenha-a privada; nunca coloque no código ou em mensagens.

## Executar
Abra Actions → “Preparar otimizacao de fotos (manual)” → Run workflow.
1. Primeiro selecione `preview`. Baixe o artefato e confira as imagens e o `manifest.json`.
2. Só depois de aprovar, execute `apply`. Baixe e guarde o artefato de backup fora do GitHub.
3. Teste o cardápio oficial e confirme que todas as fotos estão corretas.
4. A exclusão dos originais é uma etapa separada, não automatizada. Só faça depois de confirmar que o backup foi baixado e abre corretamente.

O workflow roda somente quando acionado manualmente; não altera o APK, impressão, pedidos ou outras tabelas.
