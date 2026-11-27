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

async function requeuePrintJob(db: any, jobId: string, message: string) {
  const retryAt = new Date(Date.now() + 15000).toISOString();
  const { error } = await db.from("print_jobs").update({
    status: "PENDENTE", claimed_at: null, device_id: null,
    next_attempt_at: retryAt, last_error: message
  }).eq("id", jobId).eq("status", "PROCESSANDO");
  return !error;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Método não permitido" }, 405);

  let body: { action?: string; job_id?: string; order_id?: string; error?: string; name?: string; report_date?: string } = {};
  try { body = await req.json(); } catch { return reply({ error: "JSON inválido" }, 400); }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return reply({ error: "Configuração do servidor ausente" }, 500);
  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

  if (body.action === "admin_pair" || body.action === "admin_status" || body.action === "admin_reprint" || body.action === "admin_daily_close") {
    const authHeader = req.headers.get("authorization") ?? "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) return reply({ error: "Entre novamente no painel administrativo." }, 401);
    const { data: authData, error: authError } = await db.auth.getUser(jwt);
    if (authError || !authData.user) return reply({ error: "Sessão administrativa inválida." }, 401);
    const { data: profile, error: profileError } = await db.from("admin_profiles")
      .select("is_active").eq("user_id", authData.user.id).maybeSingle();
    if (profileError || profile?.is_active !== true) return reply({ error: "Acesso restrito ao administrador ativo." }, 403);

    if (body.action === "admin_daily_close") {
      const reportDate = String(body.report_date ?? "");
      if (!/^\d{4}-\d{2}-\d{2}$/.test(reportDate)) return reply({ error: "Informe uma data válida para o fechamento." }, 400);
      const parsedDate = new Date(reportDate + "T12:00:00-03:00");
      if (Number.isNaN(parsedDate.getTime()) || parsedDate.toISOString().slice(0, 10) !== reportDate) return reply({ error: "Data inválida para o fechamento." }, 400);
      const { data: existing, error: existingError } = await db.from("print_jobs").select("id,status").eq("job_type", "DAILY_CLOSE").eq("report_date", reportDate).maybeSingle();
      if (existingError) return reply({ error: "Não foi possível verificar o fechamento já solicitado." }, 500);
      if (existing?.status === "PROCESSANDO") return reply({ error: "Este fechamento já está sendo impresso." }, 409);
      if (existing) {
        const { error: requeueError } = await db.from("print_jobs").update({ status: "PENDENTE", attempt_count: 0, last_error: null, printed_at: null, claimed_at: null, device_id: null, next_attempt_at: new Date().toISOString() }).eq("id", existing.id);
        if (requeueError) return reply({ error: "Não foi possível recolocar o fechamento na fila." }, 500);
      } else {
        const { error: queueError } = await db.from("print_jobs").insert({ job_type: "DAILY_CLOSE", report_date: reportDate, status: "PENDENTE", attempt_count: 0, next_attempt_at: new Date().toISOString() });
        if (queueError) return reply({ error: "Não foi possível criar a tarefa de fechamento." }, 500);
      }
      return reply({ ok: true, queued: true, report_date: reportDate });
    }

    if (body.action === "admin_reprint") {
      if (!body.order_id) return reply({ error: "Pedido não informado para reimpressão." }, 400);
      const { data: order, error: orderError } = await db.from("orders")
        .select("id, order_type, status")
        .eq("id", body.order_id).maybeSingle();
      if (orderError || !order) return reply({ error: "Pedido não encontrado." }, 404);
      if (!["DELIVERY", "PICKUP", "SALAO"].includes(order.order_type) || order.status === "CANCELADO") {
        return reply({ error: "Este pedido não pode ser reimpresso." }, 409);
      }
      const { data: existingJob, error: existingJobError } = await db.from("print_jobs")
        .select("id,status").eq("order_id", order.id).maybeSingle();
      if (existingJobError) return reply({ error: "Não foi possível verificar a tarefa de impressão atual." }, 500);
      if (existingJob?.status === "PROCESSANDO") {
        return reply({ error: "Este pedido já está sendo impresso. Aguarde a conclusão antes de solicitar outra via." }, 409);
      }

      const queuePayload = {
        status: "PENDENTE",
        attempt_count: 0,
        last_error: null,
        printed_at: null,
        claimed_at: null,
        device_id: null,
        next_attempt_at: new Date().toISOString()
      };
      if (existingJob) {
        const { data: requeued, error: queueError } = await db.from("print_jobs")
          .update(queuePayload).eq("id", existingJob.id).neq("status", "PROCESSANDO")
          .select("id").maybeSingle();
        if (queueError) return reply({ error: "Não foi possível colocar as duas vias na fila." }, 500);
        if (!requeued) return reply({ error: "Este pedido já está sendo impresso. Aguarde a conclusão antes de solicitar outra via." }, 409);
      } else {
        const { error: queueError } = await db.from("print_jobs")
          .insert({ ...queuePayload, order_id: order.id });
        if (queueError) return reply({ error: "Não foi possível colocar as duas vias na fila." }, 500);
      }
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
      const orderIds = staleJobs
        .filter((job: { order_id: string | null }) => job.order_id)
        .map((job: { order_id: string }) => job.order_id);
      if (orderIds.length) {
        await db.from("orders").update({ status: "FALHA_IMPRESSAO" })
          .in("id", orderIds).eq("status", "ENVIADO_IMPRESSAO");
      }
    }

    for (let attempt = 0; attempt < 3; attempt++) {
      const { data: candidate, error } = await db.from("print_jobs")
        .select("id, order_id, dining_tab_id, job_type, report_date, attempt_count")
        .eq("status", "PENDENTE")
        .lte("next_attempt_at", nowIso)
        .order("next_attempt_at", { ascending: true })
        .order("created_at", { ascending: true })
        .limit(1)
        .maybeSingle();
      if (error) return reply({ error: "Não foi possível consultar a fila." }, 500);
      if (!candidate) {
        // Se há tarefas agendadas para retry, informa o próximo horário ao APK.
        // Assim o aparelho dorme até o vencimento, sem polling periódico nem retry perdido.
        const { data: nextPending, error: nextError } = await db.from("print_jobs")
          .select("next_attempt_at")
          .eq("status", "PENDENTE")
          .gt("next_attempt_at", nowIso)
          .order("next_attempt_at", { ascending: true })
          .limit(1)
          .maybeSingle();
        if (nextError) return reply({ error: "Não foi possível consultar o próximo retry." }, 500);
        return reply({ job: null, retry_at: nextPending?.next_attempt_at ?? null });
      }

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
        .select("id, order_id, dining_tab_id, job_type, attempt_count")
        .maybeSingle();
      if (claimError) return reply({ error: "Não foi possível reservar o pedido." }, 500);
      if (!claimed) continue;

      if (claimed.job_type === "DAILY_CLOSE") {
        const reportDate = String(candidate.report_date ?? "");
        const start = new Date(reportDate + "T00:00:00-03:00");
        const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
        if (!reportDate || Number.isNaN(start.getTime())) {
          await db.from("print_jobs").update({ status: "PENDENTE", claimed_at: null, device_id: null, next_attempt_at: new Date(Date.now() + 60000).toISOString(), last_error: "Data do fechamento inválida." }).eq("id", claimed.id);
          return reply({ error: "Data do fechamento inválida." }, 500);
        }
        const [ordersResult, salonSalesResult, salonPaidResult, salonPendingResult] = await Promise.all([
          db.from("orders")
            .select("order_number,order_type,payment_method,total_cents,created_at")
            .eq("status", "ENTREGUE")
            .in("order_type", ["DELIVERY", "PICKUP"])
            .gte("created_at", start.toISOString())
            .lt("created_at", end.toISOString())
            .order("created_at", { ascending: true }),
          db.from("orders")
            .select("order_number,table_id,payment_method,payment_status,paid_payment_method,total_cents,created_at,restaurant_tables(table_number)")
            .eq("order_type", "SALAO").neq("status", "CANCELADO")
            .gte("created_at", start.toISOString()).lt("created_at", end.toISOString())
            .order("created_at", { ascending: true }),
          db.from("orders")
            .select("order_number,paid_payment_method,total_cents,paid_at,restaurant_tables(table_number)")
            .eq("order_type", "SALAO").eq("payment_status", "PAGO")
            .gte("paid_at", start.toISOString()).lt("paid_at", end.toISOString()),
          db.from("orders")
            .select("total_cents")
            .eq("order_type", "SALAO").eq("payment_status", "PENDENTE").neq("status", "CANCELADO")
            .gte("created_at", start.toISOString()).lt("created_at", end.toISOString())
        ]);
        if (ordersResult.error || salonSalesResult.error || salonPaidResult.error || salonPendingResult.error) {
          await db.from("print_jobs").update({ status: "PENDENTE", claimed_at: null, device_id: null, next_attempt_at: new Date(Date.now() + 30000).toISOString(), last_error: "Falha ao consultar as vendas do fechamento diário." }).eq("id", claimed.id);
          return reply({ error: "Não foi possível calcular as vendas do dia." }, 500);
        }

        const deliveryAndPickup = (ordersResult.data ?? []).map((sale: any) => ({
          source: sale.order_type === "PICKUP" ? "RETIRADA" : "DELIVERY",
          order_number: sale.order_number,
          total_cents: Number(sale.total_cents ?? 0),
          payment_method: sale.payment_method,
          payment_status: "PAGO",
          created_at: sale.created_at
        }));
        const salon = (salonSalesResult.data ?? []).map((sale: any) => ({
          source: "SALAO",
          order_number: sale.order_number,
          table_number: sale.restaurant_tables?.table_number ?? "N/I",
          total_cents: Number(sale.total_cents ?? 0),
          payment_method: sale.paid_payment_method ?? sale.payment_method,
          payment_status: sale.payment_status,
          created_at: sale.created_at
        }));
        const salonReceived = (salonPaidResult.data ?? []).map((sale: any) => ({
          source: "SALAO",
          order_number: sale.order_number,
          table_number: sale.restaurant_tables?.table_number ?? "N/I",
          total_cents: Number(sale.total_cents ?? 0),
          payment_method: sale.paid_payment_method,
          payment_status: "PAGO",
          created_at: sale.paid_at
        }));
        const sales = [...deliveryAndPickup, ...salon].sort(
          (a: any, b: any) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime()
        );
        const receivedSales = [...deliveryAndPickup, ...salonReceived];
        const modalityTotals = { delivery: 0, salon: 0, pickup: 0 };
        const receivedModalityTotals = { delivery: 0, salon: 0, pickup: 0 };
        const paymentTotals = { cash: 0, pix: 0, card: 0, other: 0 };
        const legacyTotals = { cash: 0, pix: 0, card: 0, other: 0 };
        const counts = { cash: 0, pix: 0, card: 0, other: 0 };
        let totalCents = 0;
        let receivedTotalCents = 0;
        const paymentKeyFor = (method: unknown) => {
          const value = String(method ?? "").trim().toUpperCase();
          return ["CASH", "DINHEIRO"].includes(value) ? "cash"
            : value === "PIX" ? "pix"
            : ["CARD", "CARTAO", "CARTÃO", "CREDIT_CARD", "DEBIT_CARD", "CARTAO_CREDITO", "CARTAO_DEBITO"].includes(value) ? "card"
            : "other";
        };
        for (const sale of sales) {
          const amount = Number(sale.total_cents || 0);
          const modalityKey = sale.source === "SALAO" ? "salon" : sale.source === "RETIRADA" ? "pickup" : "delivery";
          modalityTotals[modalityKey as keyof typeof modalityTotals] += amount;
          totalCents += amount;
        }
        for (const sale of receivedSales) {
          const amount = Number(sale.total_cents || 0);
          const modalityKey = sale.source === "SALAO" ? "salon" : sale.source === "RETIRADA" ? "pickup" : "delivery";
          receivedModalityTotals[modalityKey as keyof typeof receivedModalityTotals] += amount;
          receivedTotalCents += amount;
          const paymentKey = paymentKeyFor(sale.payment_method);
          paymentTotals[paymentKey as keyof typeof paymentTotals] += amount;
          legacyTotals[paymentKey as keyof typeof legacyTotals] += amount;
          counts[paymentKey as keyof typeof counts] += 1;
        }
        const pendingSalonTotalCents = (salonPendingResult.data ?? []).reduce(
          (sum: number, order: any) => sum + Number(order.total_cents ?? 0), 0
        );

        return reply({
          job: {
            id: claimed.id,
            job_type: "DAILY_CLOSE",
            attempt_count: claimed.attempt_count,
            report: {
              report_date: reportDate,
              sales,
              totals: legacyTotals,
              counts,
              modality_totals: modalityTotals,
              payment_totals: paymentTotals,
              received_modality_totals: receivedModalityTotals,
              total_cents: totalCents,
              received_total_cents: receivedTotalCents,
              pending_salon_total_cents: pendingSalonTotalCents,
              pending_salon_count: (salonPendingResult.data ?? []).length
            }
          }
        });
      }

      if (claimed.job_type === "TAB_CLOSE") {
        const { data: tab, error: tabError } = await db.from("dining_tabs")
          .select("id, table_id, paid_total_cents, payment_method, closed_at")
          .eq("id", claimed.dining_tab_id).maybeSingle();
        if (tabError || !tab) { await requeuePrintJob(db, claimed.id, "Comanda não encontrada; nova tentativa programada."); return reply({ error: "Comanda fechada não encontrada." }, 500); }
        const { data: table, error: tableError } = await db.from("restaurant_tables")
          .select("table_number").eq("id", tab.table_id).maybeSingle();
        if (tableError || !table) { await requeuePrintJob(db, claimed.id, "Mesa não encontrada; nova tentativa programada."); return reply({ error: "Mesa não encontrada." }, 500); }
        const { data: orders, error: ordersError } = await db.from("orders")
          .select("id, order_number, total_cents, customer_notes, created_at")
          .eq("dining_tab_id", tab.id).neq("status", "CANCELADO").order("created_at", { ascending: true });
        if (ordersError) { await requeuePrintJob(db, claimed.id, "Falha ao carregar pedidos da comanda; nova tentativa programada."); return reply({ error: "Não foi possível carregar os pedidos da comanda." }, 500); }
        const orderIds = (orders ?? []).map((o: { id: string }) => o.id);
        const { data: items, error: itemsError } = orderIds.length
          ? await db.from("order_items").select("id, order_id, product_name_snapshot, unit_price_cents, quantity, notes").in("order_id", orderIds)
          : { data: [], error: null };
        if (itemsError) { await requeuePrintJob(db, claimed.id, "Falha ao carregar itens da comanda; nova tentativa programada."); return reply({ error: "Não foi possível carregar os itens da comanda." }, 500); }
        const itemIds = (items ?? []).map((i: { id: string }) => i.id);
        const { data: accompaniments, error: accError } = itemIds.length
          ? await db.from("order_item_accompaniments").select("order_item_id, accompaniment_name, unit_index").in("order_item_id", itemIds)
          : { data: [], error: null };
        if (accError) { await requeuePrintJob(db, claimed.id, "Falha ao carregar acompanhamentos da comanda; nova tentativa programada."); return reply({ error: "Não foi possível carregar os acompanhamentos." }, 500); }
        const order = { order_type: "TAB_CLOSE", table_number: table.table_number,
          total_cents: tab.paid_total_cents ?? 0, payment_method: tab.payment_method,
          created_at: tab.closed_at, order_count: orders?.length ?? 0 };
        return reply({ job: { id: claimed.id, job_type: "TAB_CLOSE", attempt_count: claimed.attempt_count,
          order, orders: orders ?? [], items: items ?? [], accompaniments: accompaniments ?? [] } });
      }

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

      const orderForPrint = { ...order, table_number: null as number | null };
      if (order.order_type === "SALAO" && order.table_id) {
        const { data: table, error: tableError } = await db.from("restaurant_tables")
          .select("table_number").eq("id", order.table_id).maybeSingle();
        if (tableError || !table) {
          const retryAt = new Date(Date.now() + 15000).toISOString();
          await db.from("print_jobs").update({
            status: "PENDENTE", claimed_at: null, device_id: null,
            next_attempt_at: retryAt, last_error: "Mesa não encontrada; nova tentativa programada."
          }).eq("id", claimed.id);
          return reply({ error: "Não foi possível identificar a mesa do pedido." }, 500);
        }
        orderForPrint.table_number = table.table_number;
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
      return reply({ job: { id: claimed.id, attempt_count: claimed.attempt_count, order: orderForPrint, items: items ?? [], accompaniments } });
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
      if (current.order_id) await db.from("orders").update({ status: "IMPRESSO" })
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
    if (current.order_id) await db.from("orders").update({ status: "FALHA_IMPRESSAO" })
      .eq("id", current.order_id)
      .in("status", ["APROVADO", "ENVIADO_IMPRESSAO", "IMPRESSO", "FALHA_IMPRESSAO"]);
    return reply({ ok: true, retry_in_seconds: delaySeconds });
  }

  return reply({ error: "Ação inválida" }, 400);
});