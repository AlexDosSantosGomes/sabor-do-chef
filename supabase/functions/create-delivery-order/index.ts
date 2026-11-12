import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://alexdossantosgomes.github.io",
  "https://cardapiosabordochef.com.br",
  "https://www.cardapiosabordochef.com.br",
]);

function corsHeaders(origin: string | null) {
  return {
    "Access-Control-Allow-Origin": origin && allowedOrigins.has(origin) ? origin : "https://cardapiosabordochef.com.br",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function jsonResponse(body: unknown, status = 200, origin: string | null = null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(origin) });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Método não permitido." }, 405, origin);
  }

  if (!origin || !allowedOrigins.has(origin)) {
    return jsonResponse({ error: "Origem não autorizada." }, 403, origin);
  }

  const contentLength = Number(req.headers.get("content-length") || "0");
  if (contentLength > 20000) {
    return jsonResponse({ error: "Pedido muito grande." }, 413, origin);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Não foi possível ler os dados do pedido." }, 400, origin);
  }

  const customerName = typeof body.customer_name === "string" ? body.customer_name.trim() : "";
  const customerPhone = typeof body.customer_phone === "string" ? body.customer_phone.trim() : "";
  const customerNotes = typeof body.customer_notes === "string" ? body.customer_notes.trim() : "";
  const deliveryAddress = typeof body.delivery_address === "string" ? body.delivery_address.trim() : "";
  const orderType = body.order_type === "PICKUP" ? "PICKUP" : "DELIVERY";
  const paymentMethod = body.payment_method;
  const needsChange = body.needs_change === true;
  const changeForCents = body.change_for_cents === null || body.change_for_cents === undefined
    ? null
    : Number(body.change_for_cents);
  const items = body.items;

  if (
    customerName.length < 2 || customerName.length > 100 ||
    customerPhone.length < 10 || customerPhone.length > 25 ||
    (orderType === "DELIVERY" && (deliveryAddress.length < 8 || deliveryAddress.length > 300)) ||
    (orderType === "PICKUP" && deliveryAddress.length > 0)
  ) {
    return jsonResponse({ error: "Confira nome, telefone e endereço." }, 400, origin);
  }

  if (customerNotes.length > 300) {
    return jsonResponse({ error: "A observação deve ter no máximo 300 caracteres." }, 400, origin);
  }

  if (!["CASH", "PIX", "CARD"].includes(String(paymentMethod))) {
    return jsonResponse({ error: "Escolha uma forma de pagamento válida." }, 400, origin);
  }

  if (needsChange && (
    paymentMethod !== "CASH" ||
    !Number.isInteger(changeForCents) ||
    (changeForCents as number) <= 0
  )) {
    return jsonResponse({ error: "Confira o valor para troco." }, 400, origin);
  }

  if (!needsChange && changeForCents !== null) {
    return jsonResponse({ error: "Dados de troco inválidos." }, 400, origin);
  }

  if (!Array.isArray(items) || items.length < 1 || items.length > 30) {
    return jsonResponse({ error: "Seu carrinho está vazio ou tem itens demais." }, 400, origin);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const secretKeysRaw = Deno.env.get("SUPABASE_SECRET_KEYS");
  let secretKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!secretKey && secretKeysRaw) {
    try {
      const secretKeys = JSON.parse(secretKeysRaw);
      secretKey = secretKeys.default || "";
    } catch {
      return jsonResponse({ error: "Configuração segura do servidor inválida." }, 500, origin);
    }
  }

  if (!supabaseUrl || !secretKey) {
    return jsonResponse({ error: "Servidor ainda não está configurado." }, 500, origin);
  }

  const admin = createClient(supabaseUrl, secretKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data, error } = await admin.rpc("create_customer_order", {
    p_order_type: orderType,
    p_customer_name: customerName,
    p_customer_phone: customerPhone,
    p_delivery_address: deliveryAddress,
    p_payment_method: paymentMethod,
    p_needs_change: needsChange,
    p_change_for_cents: needsChange ? changeForCents : null,
    p_items: items,
    p_customer_notes: customerNotes || null,
  });

  if (error) {
    const safeMessage = error.message || "Não foi possível registrar o pedido.";
    return jsonResponse({ error: safeMessage }, 400, origin);
  }

  let pushRegistered = false;
  const sub = body.push_subscription;
  if (sub && typeof sub.endpoint === "string" && sub.endpoint.startsWith("https://") &&
      typeof sub.keys?.p256dh === "string" && typeof sub.keys?.auth === "string" &&
      sub.endpoint.length < 2000 && sub.keys.p256dh.length < 200 && sub.keys.auth.length < 200) {
    const { error: pushError } = await admin.from("delivery_push_subscriptions").upsert({
      order_id: data.order_id, endpoint: sub.endpoint, p256dh: sub.keys.p256dh, auth: sub.keys.auth
    }, { onConflict: "order_id,endpoint" });
    if (!pushError) pushRegistered = true;
    else console.error("Falha ao salvar inscrição push", pushError.message);
  }
  return jsonResponse({ success: true, order_number: data.order_number, total_cents: data.total_cents, push_registered: pushRegistered }, 200, origin);
});
