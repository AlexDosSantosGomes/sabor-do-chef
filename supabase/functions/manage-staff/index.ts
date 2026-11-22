import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Método não permitido." }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply({ error: "Configuração do servidor ausente." }, 500);

  const db = createClient(url, serviceKey, { auth: { persistSession: false } });
  const auth = req.headers.get("Authorization") ?? "";
  const jwt = auth.replace(/^Bearer\s+/i, "");
  if (!jwt) return reply({ error: "Entre como administrador." }, 401);

  const { data: authData, error: authError } = await db.auth.getUser(jwt);
  const actor = authData.user;
  if (authError || !actor) return reply({ error: "Sessão inválida." }, 401);

  const { data: admin, error: adminError } = await db.from("admin_profiles")
    .select("is_active").eq("user_id", actor.id).maybeSingle();
  if (adminError || admin?.is_active !== true) {
    return reply({ error: "Somente administrador ativo pode gerenciar funcionários." }, 403);
  }

  let body: { action?: string; email?: string; display_name?: string; role?: string; user_id?: string; is_active?: boolean } = {};
  try { body = await req.json(); } catch { return reply({ error: "JSON inválido." }, 400); }

  if (body.action === "list") {
    const { data: roles, error } = await db.from("user_roles")
      .select("user_id,role,is_active,created_at").order("created_at", { ascending: false });
    if (error) return reply({ error: "Não foi possível carregar os funcionários." }, 500);
    const users = await Promise.all((roles ?? []).map(async (row) => {
      const { data } = await db.auth.admin.getUserById(row.user_id);
      return { ...row, email: data.user?.email ?? "E-mail indisponível" };
    }));
    return reply({ users });
  }

  if (body.action === "invite") {
    const email = String(body.email ?? "").trim().toLowerCase();
    const displayName = String(body.display_name ?? "").trim();
    const role = String(body.role ?? "");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return reply({ error: "Informe um e-mail válido." }, 400);
    if (displayName.length < 2 || displayName.length > 80) return reply({ error: "Informe o nome do funcionário (2 a 80 caracteres)." }, 400);
    if (!["DELIVERY", "SALON"].includes(role)) return reply({ error: "Perfil inválido." }, 400);

    let invitedUser = null;
    const { data: invited, error: inviteError } = await db.auth.admin.inviteUserByEmail(email, {
      data: { display_name: displayName },
      redirectTo: "https://cardapiosabordochef.com.br/portal-funcionarios.html"
    });
    invitedUser = invited.user;
    if (inviteError || !invitedUser) {
      const { data: list } = await db.auth.admin.listUsers({ page: 1, perPage: 1000 });
      const existing = list?.users?.find((u) => u.email?.toLowerCase() === email);
      if (!existing) return reply({ error: inviteError?.message ?? "Não foi possível convidar este e-mail." }, 400);
      invitedUser = existing;
    }

    const { error: roleError } = await db.from("user_roles").upsert({
      user_id: invitedUser.id,
      role,
      is_active: true,
      created_by: actor.id,
      updated_at: new Date().toISOString()
    }, { onConflict: "user_id" });
    if (roleError) return reply({ error: "Conta encontrada/convidada, mas não foi possível salvar o perfil: " + roleError.message, user_id: invitedUser.id }, 500);
    return reply({ ok: true, user_id: invitedUser.id, email, role, invited: !inviteError });
  }

  if (body.action === "generate_password_link") {
    if (!body.user_id) return reply({ error: "Funcionário não informado." }, 400);
    const { data: staffRole, error: staffRoleError } = await db.from("user_roles")
      .select("user_id,is_active").eq("user_id", body.user_id).maybeSingle();
    if (staffRoleError || !staffRole) return reply({ error: "Funcionário não encontrado." }, 404);
    if (staffRole.is_active !== true) return reply({ error: "Ative o funcionário antes de gerar um link de senha." }, 400);

    const { data: staffUser, error: staffUserError } = await db.auth.admin.getUserById(body.user_id);
    const email = staffUser?.user?.email;
    if (staffUserError || !email) return reply({ error: "Não foi possível localizar o e-mail do funcionário." }, 404);
    const linkType = staffUser.user.email_confirmed_at ? "recovery" : "invite";

    const { data: generated, error: generateError } = await db.auth.admin.generateLink({
      type: linkType,
      email,
      options: { redirectTo: "https://cardapiosabordochef.com.br/portal-funcionarios.html" }
    });
    const actionLink = generated?.properties?.action_link;
    if (generateError || !actionLink) {
      return reply({ error: generateError?.message ?? "Não foi possível gerar o link de senha." }, 400);
    }
    return reply({ ok: true, user_id: body.user_id, email, action_link: actionLink });
  }

  if (body.action === "set_active") {
    if (!body.user_id || typeof body.is_active !== "boolean") return reply({ error: "Dados de ativação inválidos." }, 400);
    const { error } = await db.from("user_roles")
      .update({ is_active: body.is_active, updated_at: new Date().toISOString() })
      .eq("user_id", body.user_id);
    if (error) return reply({ error: "Não foi possível atualizar o funcionário." }, 500);
    return reply({ ok: true });
  }

  return reply({ error: "Ação inválida." }, 400);
});
