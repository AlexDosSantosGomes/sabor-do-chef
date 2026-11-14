import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-device-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Método não permitido" }, 405);

  let body: { action?: string; job_id?: string; order_id?: string; error?: string; name?: string } = {};
  try { body = await req.json(); } catch { return reply({ error: "JSON inválido" }, 400); }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return reply({ error: "Configuração do servidor ausente" }, 500);
  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

  if (body.action === "admin_pair" || body.action === "admin_status") {
    const authHeader = req.headers.get("authorization") ?? "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) return reply({ error: "Entre novamente no painel administrativo." }, 401);
    const { data: authData, error: authError } = await db.auth.getUser(jwt);
    if (authError || !authData.user) return reply({ error: "Sessão administrativa inválida." }, 401);
    const { data: profile, error: profileError } = await db.from("admin_profiles")
      .select("is_active").eq("user_id", authData.user.id).maybeSingle();
    if (profileError || profile?.is_active !== true) return reply({ error: "Acesso restrito ao administrador ativo." }, 403);

    if (body.action === "admin_reprint") {
      if (!body.order_id) return reply({ error: "Pedido não informado para reimpressão." }, 400);
      const { data: order, error: orderError } = await db.from("orders")
        .select("id, order_type, status")
        .eq("id", body.order_id).maybeSingle();
      if (orderError || !order) return reply({ error: "Pedido não encontrado." }, 404);
      if (!["DELIVERY", "PICKUP"].includes(order.order_type) || order.status === "CANCELADO") {
        return reply({ error: "Este pedido não pode ser reimpresso." }, 409);
      }
      const { error: queueError } = await db.from("print_jobs").upsert({
        order_id: order.id,
        status: "PENDENTE",
        attempt_count: 0,
        last_error: null,
        printed_at: null,
        claimed_at: null,
        device_id: null,
        next_attempt_at: new Date().toISOString()
      }, { onConflict: "order_id" });
      if (queueError) return reply({ error: "Não foi possível colocar as duas vias na fila." }, 500);
      return reply({ ok: true, queued: true });
    }

    if (body.action === "admin_pair") {
      const token = randomToken();
      const name = String(body.name ?? "Central Android").trim().slice(0, 80) || "Central Android";
      const { error } = await db.from("printer_devices").insert({
        name, token_hash: await sha256(token), active: true
      });
      if (error) return reply({ error: "Não foi possível registrar o aparelho." }, 500);
      return reply({ ok: true, name, device_token: token });
    }

    const { data: devices, error } = await db.from("printer_devices")
      .select("id, name, active, last_seen_at, created_at")
      .order("created_at", { ascending: false });
    if (error) return reply({ error: "Não foi possível consultar os aparelhos." }, 500);
    return reply({ devices: devices ?? [] });
  }

  const token = req.headers.get("x-device-token") ?? "";
  if (token.length < 32) return reply({ error: "Dispositivo não autorizado" }, 401);
  const tokenHash = await sha256(token);
  const { data: device, error: deviceError } = await db.from("printer_devices")
    .select("id, name, last_seen_at").eq("token_hash", tokenHash).eq("active", true).maybeSingle();
  if (deviceError || !device) return reply({ error: "Dispositivo não autorizado" }, 401);

  const lastSeenMs = device.last_seen_at ? new Date(device.last_seen_at).getTime() : 0;
  if (!lastSeenMs || Date.now() - lastSeenMs >= 60_000) {
    await db.from("printer_devices")
      .update({ last_seen_at: new Date().toISOString() }).eq("id", device.id);
  }

  if (body.action === "claim") {
    const now = new Date();
    const nowIso = now.toISOString();
    const staleBefore = new Date(now.getTime() - 3 * 60 * 1000).toISOString();

    // Recoloca na fila tarefas cujo Android parou de responder durante a impressão.
    const { data: staleJobs, error: staleError } = await db.from("print_jobs")
      .select("id, order_id")
      .eq("status", "PROCESSANDO")
      .lt("claimed_at", staleBefore);
    if (staleError) return reply({ error: "Não foi possível recuperar tarefas interrompidas." }, 500);
    if (staleJobs?.length) {
      const staleIds = staleJobs.map((job: { id: string }) => job.id);
      await db.from("print_jobs").update({
        status: "PENDENTE",
        claimed_at: null,
        device_id: null,
        next_attempt_at: nowIso,
        last_error: "Conexão interrompida durante a impressão; tarefa recolocada na fila."
      }).in("id", staleIds).eq("status", "PROCESSANDO");
      const orderIds = staleJobs.map((job: { order_id: string }) => job.order_id);
      await db.from("orders").update({ status: "FALHA_IMPRESSAO" })
        .in("id", orderIds).eq("status", "ENVIADO_IMPRESSAO");
    }

    for (let attempt = 0; attempt < 3; attempt++) {
      const { data: candidate, error } = await db.from("print_jobs")
        .select("id, order_id, attempt_count")
        .eq("status", "PENDENTE")
        .lte("next_attempt_at", nowIso)
        .order("next_attempt_at", { ascending: true })
        .order("created_at", { ascending: true })
        .limit(1)
        .maybeSingle();
      if (error) return reply({ error: "Não foi possível consultar a fila." }, 500);
      if (!candidate) return reply({ job: null });

      const claimedAt = new Date().toISOString();
      const { data: claimed, error: claimError } = await db.from("print_jobs")
        .update({
          status: "PROCESSANDO",
          claimed_at: claimedAt,
          last_attempt_at: claimedAt,
          next_attempt_at: null,
          device_id: device.id,
          attempt_count: (candidate.attempt_count ?? 0) + 1
        })
        .eq("id", candidate.id)
        .eq("status", "PENDENTE")
        .select("id, order_id, attempt_count")
        .maybeSingle();
      if (claimError) return reply({ error: "Não foi possível reservar o pedido." }, 500);
      if (!claimed) continue;

      await db.from("orders").update({ status: "ENVIADO_IMPRESSAO" })
        .eq("id", claimed.order_id)
        .in("status", ["APROVADO", "FALHA_IMPRESSAO", "ENVIADO_IMPRESSAO"]);

      const { data: order, error: orderError } = await db.from("orders")
        .select("id, order_number, order_type, customer_name, customer_phone, delivery_address, payment_method, total_cents, customer_notes, created_at, table_id, needs_change, change_for_cents")
        .eq("id", claimed.order_id).maybeSingle();
      if (orderError || !order) {
        const retryAt = new Date(Date.now() + 15000).toISOString();
        await db.from("print_jobs").update({
          status: "PENDENTE", claimed_at: null, device_id: null,
          next_attempt_at: retryAt, last_error: "Pedido não encontrado; nova tentativa programada."
        }).eq("id", claimed.id);
        return reply({ error: "Pedido não encontrado" }, 500);
      }

      const { data: items, error: itemsError } = await db.from("order_items")
        .select("id, product_name_snapshot, unit_price_cents, quantity, notes")
        .eq("order_id", order.id);
      if (itemsError) {
        const retryAt = new Date(Date.now() + 15000).toISOString();
        await db.from("print_jobs").update({
          status: "PENDENTE", claimed_at: null, device_id: null,
          next_attempt_at: retryAt, last_error: "Falha ao carregar itens; nova tentativa programada."
        }).eq("id", claimed.id);
        return reply({ error: "Não foi possível carregar os itens." }, 500);
      }

      const itemIds = (items ?? []).map((item: { id: string }) => item.id);
      let accompaniments: unknown[] = [];
      if (itemIds.length) {
        const { data, error: accError } = await db.from("order_item_accompaniments")
          .select("order_item_id, accompaniment_name, unit_index")
          .in("order_item_id", itemIds);
        if (accError) {
          const retryAt = new Date(Date.now() + 15000).toISOString();
          await db.from("print_jobs").update({
            status: "PENDENTE", claimed_at: null, device_id: null,
            next_attempt_at: retryAt, last_error: "Falha ao carregar acompanhamentos; nova tentativa programada."
          }).eq("id", claimed.id);
          return reply({ error: "Não foi possível carregar acompanhamentos." }, 500);
        }
        accompaniments = data ?? [];
      }
      return reply({ job: { id: claimed.id, attempt_count: claimed.attempt_count, order, items: items ?? [], accompaniments } });
    }
    return reply({ job: null });
  }

  if (body.action === "complete" || body.action === "fail") {
    if (!body.job_id) return reply({ error: "Identificador do serviço ausente" }, 400);

    const { data: current, error: readError } = await db.from("print_jobs")
      .select("id, order_id, status, device_id, attempt_count")
      .eq("id", body.job_id).maybeSingle();
    if (readError || !current) return reply({ error: "Tarefa de impressão não encontrada." }, 404);

    if (body.action === "complete") {
      // Torna a confirmação idempotente: repetir o ACK não reabre nem duplica a tarefa.
      if (current.status === "IMPRESSO" && current.device_id === device.id) return reply({ ok: true, already_completed: true });
      if (current.device_id !== device.id || current.status !== "PROCESSANDO") {
        return reply({ error: "Tarefa não pertence a este aparelho ou já foi finalizada." }, 409);
      }
      const printedAt = new Date().toISOString();
      const { data, error } = await db.from("print_jobs").update({
        status: "IMPRESSO", printed_at: printedAt, claimed_at: null, next_attempt_at: null, last_error: null
      }).eq("id", body.job_id).eq("device_id", device.id).eq("status", "PROCESSANDO")
        .select("id").maybeSingle();
      if (error) return reply({ error: "Não foi possível confirmar o envio à impressora." }, 500);
      if (!data) return reply({ error: "Tarefa já alterada; atualize o painel." }, 409);
      await db.from("orders").update({ status: "IMPRESSO" })
        .eq("id", current.order_id)
        .in("status", ["APROVADO", "ENVIADO_IMPRESSAO", "FALHA_IMPRESSAO"]);
      return reply({ ok: true });
    }

    if (current.device_id !== device.id || current.status !== "PROCESSANDO") {
      if (current.status === "PENDENTE") return reply({ ok: true, already_queued: true });
      return reply({ error: "Tarefa não pertence a este aparelho ou já foi finalizada." }, 409);
    }

    const attemptCount = Math.max(1, Number(current.attempt_count) || 1);
    const delaySeconds = Math.min(300, 5 * (2 ** Math.min(attemptCount - 1, 6)));
    const nextAttempt = new Date(Date.now() + delaySeconds * 1000).toISOString();
    const message = String(body.error ?? "Falha ao enviar via Bluetooth").slice(0, 500);
    const { error } = await db.from("print_jobs").update({
      status: "PENDENTE",
      claimed_at: null,
      device_id: null,
      next_attempt_at: nextAttempt,
      last_error: message
    }).eq("id", body.job_id).eq("device_id", device.id).eq("status", "PROCESSANDO");
    if (error) return reply({ error: "Não foi possível reagendar a impressão." }, 500);
    await db.from("orders").update({ status: "FALHA_IMPRESSAO" })
      .eq("id", current.order_id)
      .in("status", ["APROVADO", "ENVIADO_IMPRESSAO", "IMPRESSO", "FALHA_IMPRESSAO"]);
    return reply({ ok: true, retry_in_seconds: delaySeconds });
  }

  return reply({ error: "Ação inválida" }, 400);
});