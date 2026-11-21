-- Salon QR order approval and accountable tab closing.
create or replace function public.set_salon_order_action(
  p_order_id uuid,
  p_action text,
  p_reason text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status public.order_status;
  v_type public.order_type;
begin
  if (select auth.uid()) is null then
    raise exception 'É necessário entrar com uma conta autorizada.';
  end if;
  if not (private.is_active_admin() or private.has_staff_role('SALON')) then
    raise exception 'Acesso restrito à equipe do salão.';
  end if;

  select order_type, status into v_type, v_status
  from public.orders where id = p_order_id for update;

  if not found then raise exception 'Pedido não encontrado.'; end if;
  if v_type <> 'SALAO'::public.order_type then
    raise exception 'Este pedido não pertence ao salão.';
  end if;

  if p_action = 'APPROVE' then
    if v_status not in ('RECEBIDO'::public.order_status, 'AGUARDANDO_APROVACAO'::public.order_status) then
      raise exception 'Este pedido não está aguardando aprovação.';
    end if;
    update public.orders
       set status = 'APROVADO',
           approved_by = case when private.is_active_admin() then (select auth.uid()) else null end,
           approved_at = now(),
           cancellation_reason = null,
           cancelled_at = null
     where id = p_order_id;
  elsif p_action = 'REJECT' then
    if v_status not in ('RECEBIDO'::public.order_status, 'AGUARDANDO_APROVACAO'::public.order_status) then
      raise exception 'Somente pedidos aguardando aprovação podem ser recusados.';
    end if;
    if length(trim(coalesce(p_reason, ''))) < 3 or length(p_reason) > 300 then
      raise exception 'Informe o motivo da recusa (3 a 300 caracteres).';
    end if;
    update public.orders
       set status = 'CANCELADO',
           cancellation_reason = trim(p_reason),
           cancelled_at = now()
     where id = p_order_id;
  else
    raise exception 'Ação inválida.';
  end if;
  return true;
end;
$$;
revoke all on function public.set_salon_order_action(uuid, text, text) from public, anon;
grant execute on function public.set_salon_order_action(uuid, text, text) to authenticated;

alter table public.dining_tabs
  add column if not exists payment_method text,
  add column if not exists paid_total_cents integer;

create or replace function public.close_dining_tab_with_payment(
  p_tab_id uuid,
  p_payment_method text,
  p_closing_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total bigint;
  v_status text;
begin
  if (select auth.uid()) is null then
    raise exception 'É necessário entrar com uma conta autorizada.';
  end if;
  if not (private.is_active_admin() or private.has_staff_role('SALON')) then
    raise exception 'Acesso restrito à equipe do salão.';
  end if;
  if p_payment_method not in ('DINHEIRO', 'PIX', 'CARTAO') then
    raise exception 'Selecione uma forma de pagamento válida.';
  end if;
  if length(coalesce(p_closing_note, '')) > 300 then
    raise exception 'Observação deve ter até 300 caracteres.';
  end if;

  select status into v_status
    from public.dining_tabs
   where id = p_tab_id
   for update;
  if not found or v_status <> 'OPEN' then
    raise exception 'Comanda não encontrada ou já fechada.';
  end if;

  if exists (
    select 1 from public.orders
     where dining_tab_id = p_tab_id
       and status in ('RECEBIDO'::public.order_status, 'AGUARDANDO_APROVACAO'::public.order_status)
  ) then
    raise exception 'Há pedidos aguardando aceite ou recusa. Resolva-os antes de fechar a conta.';
  end if;

  select coalesce(sum(total_cents), 0) into v_total
    from public.orders
   where dining_tab_id = p_tab_id
     and status <> 'CANCELADO'::public.order_status;

  update public.dining_tabs
     set status = 'CLOSED',
         closed_by = (select auth.uid()),
         closed_at = now(),
         closing_note = nullif(trim(coalesce(p_closing_note, '')), ''),
         payment_method = p_payment_method,
         paid_total_cents = v_total
   where id = p_tab_id;

  update public.orders
     set status = 'ENTREGUE'
   where dining_tab_id = p_tab_id
     and status in (
       'APROVADO'::public.order_status,
       'ENVIADO_IMPRESSAO'::public.order_status,
       'IMPRESSO'::public.order_status,
       'FALHA_IMPRESSAO'::public.order_status
     );

  return jsonb_build_object('tab_id', p_tab_id, 'total_cents', v_total, 'payment_method', p_payment_method);
end;
$$;
revoke all on function public.close_dining_tab_with_payment(uuid, text, text) from public, anon;
grant execute on function public.close_dining_tab_with_payment(uuid, text, text) to authenticated;

revoke all on function public.close_dining_tab(uuid, text) from public, anon, authenticated;
