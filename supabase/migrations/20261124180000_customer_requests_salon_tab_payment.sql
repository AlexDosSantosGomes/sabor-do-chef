-- Cliente solicita o fechamento; o funcionário confirma o pagamento no caixa.
begin;

alter table public.dining_tabs
  add column if not exists payment_requested_at timestamptz;

alter table public.dining_tabs
  drop constraint if exists dining_tabs_status_check;
alter table public.dining_tabs
  add constraint dining_tabs_status_check
  check (status = any (array['OPEN'::text, 'PAYMENT_REQUESTED'::text, 'CLOSED'::text]));

alter table public.dining_tabs
  drop constraint if exists dining_tabs_check;
alter table public.dining_tabs
  add constraint dining_tabs_check
  check (
    ((status = any (array['OPEN'::text, 'PAYMENT_REQUESTED'::text])) and closed_at is null)
    or (status = 'CLOSED'::text and closed_at is not null)
  );

drop index if exists public.dining_tabs_one_open_per_table;
create unique index dining_tabs_one_open_per_table
  on public.dining_tabs (table_id)
  where status = any (array['OPEN'::text, 'PAYMENT_REQUESTED'::text]);

create or replace function public.get_salon_qr_context(p_qr_token uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_table_id uuid;
  v_number integer;
  v_tab_id uuid;
  v_tab_status text;
  v_total bigint := 0;
  v_requested_at timestamptz;
begin
  select id, table_number
    into v_table_id, v_number
    from public.restaurant_tables
   where qr_token = p_qr_token and active = true;

  if not found then
    raise exception 'QR Code inválido ou mesa desativada.';
  end if;

  select id, status, payment_requested_at
    into v_tab_id, v_tab_status, v_requested_at
    from public.dining_tabs
   where table_id = v_table_id
     and status in ('OPEN', 'PAYMENT_REQUESTED')
   order by opened_at desc
   limit 1;

  if v_tab_id is not null then
    select coalesce(sum(total_cents), 0)
      into v_total
      from public.orders
     where dining_tab_id = v_tab_id
       and status <> 'CANCELADO'::public.order_status;
  end if;

  return jsonb_build_object(
    'table_number', v_number,
    'has_open_tab', v_tab_status = 'OPEN',
    'tab_status', v_tab_status,
    'tab_total_cents', v_total,
    'payment_requested_at', v_requested_at
  );
end;
$function$;

revoke all on function public.get_salon_qr_context(uuid) from public;
grant execute on function public.get_salon_qr_context(uuid) to anon, authenticated;

create or replace function public.request_salon_tab_payment(p_qr_token uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_table_id uuid;
  v_tab_id uuid;
  v_status text;
  v_total bigint := 0;
  v_requested_at timestamptz;
begin
  if p_qr_token is null then
    raise exception 'QR Code inválido.';
  end if;

  select id
    into v_table_id
    from public.restaurant_tables
   where qr_token = p_qr_token and active = true;

  if not found then
    raise exception 'QR Code inválido ou mesa desativada.';
  end if;

  select id, status, payment_requested_at
    into v_tab_id, v_status, v_requested_at
    from public.dining_tabs
   where table_id = v_table_id
     and status in ('OPEN', 'PAYMENT_REQUESTED')
   order by opened_at desc
   limit 1
   for update;

  if not found then
    raise exception 'Não existe uma comanda aberta nesta mesa.';
  end if;

  select coalesce(sum(total_cents), 0)
    into v_total
    from public.orders
   where dining_tab_id = v_tab_id
     and status <> 'CANCELADO'::public.order_status;

  if v_status = 'OPEN' then
    update public.dining_tabs
       set status = 'PAYMENT_REQUESTED',
           payment_requested_at = now()
     where id = v_tab_id
     returning payment_requested_at into v_requested_at;
  end if;

  return jsonb_build_object(
    'tab_id', v_tab_id,
    'status', 'PAYMENT_REQUESTED',
    'total_cents', v_total,
    'already_requested', v_status = 'PAYMENT_REQUESTED',
    'payment_requested_at', v_requested_at
  );
end;
$function$;

revoke all on function public.request_salon_tab_payment(uuid) from public;
grant execute on function public.request_salon_tab_payment(uuid) to anon, authenticated;

create or replace function public.reopen_dining_tab_after_payment_cancel(p_tab_id uuid)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_status text;
begin
  if (select auth.uid()) is null then
    raise exception 'É necessário entrar com uma conta autorizada.';
  end if;

  if not (private.is_active_admin() or private.has_staff_role('SALON')) then
    raise exception 'Acesso restrito à equipe do salão.';
  end if;

  select status
    into v_status
    from public.dining_tabs
   where id = p_tab_id
   for update;

  if not found or v_status <> 'PAYMENT_REQUESTED' then
    raise exception 'A comanda não está aguardando pagamento.';
  end if;

  update public.dining_tabs
     set status = 'OPEN',
         payment_requested_at = null
   where id = p_tab_id;

  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, details)
  select ap.user_id,
         'REOPENED_DINING_TAB',
         'dining_tab',
         p_tab_id,
         jsonb_build_object('reason', 'payment_request_cancelled')
    from public.admin_profiles ap
   where ap.user_id = (select auth.uid())
     and ap.is_active = true;

  return true;
end;
$function$;

revoke all on function public.reopen_dining_tab_after_payment_cancel(uuid) from public;
grant execute on function public.reopen_dining_tab_after_payment_cancel(uuid) to authenticated;

commit;
