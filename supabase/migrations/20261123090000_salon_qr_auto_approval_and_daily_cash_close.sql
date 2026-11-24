-- QR do Salão: pedidos do cliente são aprovados automaticamente e entram na fila existente.
-- Preserva validações de estoque, acompanhamentos por unidade e limite de 2 acompanhamentos.
alter table public.orders add column if not exists order_source text not null default 'STAFF';
alter table public.orders drop constraint if exists orders_order_source_check;
alter table public.orders add constraint orders_order_source_check
  check (order_source in ('CLIENT_QR','STAFF'));

create or replace function public.mark_salon_order_source()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $source$
begin
  if new.order_type='SALAO'::public.order_type then
    new.order_source := case when auth.uid() is null then 'CLIENT_QR' else 'STAFF' end;
  end if;
  return new;
end;
$source$;
-- Trigger-only function: callers must not invoke it through the Data API.
revoke all on function public.mark_salon_order_source() from public, anon, authenticated;
drop trigger if exists orders_mark_salon_source on public.orders;
create trigger orders_mark_salon_source before insert on public.orders
for each row execute function public.mark_salon_order_source();

-- Mantém um único trigger de enfileiramento. A instalação anterior usa
-- trg_enqueue_delivery_print_job; removemos os nomes conhecidos antes de padronizar.
drop trigger if exists trg_enqueue_delivery_print_job on public.orders;
drop trigger if exists orders_enqueue_print_job_auto on public.orders;
create trigger orders_enqueue_print_job_auto
after insert or update of status on public.orders
for each row execute function public.enqueue_delivery_print_job();
create or replace function public.create_salon_qr_order(
  p_qr_token uuid,
  p_items jsonb,
  p_customer_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_table_id uuid; v_tab_id uuid; v_number integer;
  v_item jsonb; v_product_id uuid; v_qty integer;
  v_name text; v_price integer; v_stock integer; v_active boolean;
  v_total integer := 0; v_order_id uuid; v_order_number bigint;
  v_order_item_id uuid; v_notes text;
  v_sides_by_unit jsonb; v_unit_sides jsonb; v_side text;
  v_side_count integer; v_unit_index integer;
begin
  select id, table_number into v_table_id, v_number
  from public.restaurant_tables
  where qr_token = p_qr_token and active = true;
  if not found then raise exception 'QR Code inválido ou mesa desativada.'; end if;

  select id into v_tab_id
  from public.dining_tabs
  where table_id = v_table_id and status = 'OPEN'
  for update;
  if v_tab_id is null then raise exception 'A mesa ainda não está recebendo pedidos. Chame um funcionário.'; end if;

  if length(trim(coalesce(p_customer_notes, ''))) > 300 then
    raise exception 'A observação deve ter no máximo 300 caracteres.';
  end if;
  if coalesce(jsonb_typeof(p_items), '') <> 'array'
     or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 30 then
    raise exception 'Adicione entre 1 e 30 produtos.';
  end if;
  if (select count(distinct (x->>'product_id')::uuid)
      from jsonb_array_elements(p_items) x) <> jsonb_array_length(p_items) then
    raise exception 'Há produtos repetidos no carrinho.';
  end if;

  for v_item in
    select value from jsonb_array_elements(p_items)
    order by (value->>'product_id')::uuid
  loop
    if coalesce(v_item->>'quantity', '') !~ '^[0-9]+$' then raise exception 'Quantidade inválida.'; end if;
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty < 1 or v_qty > 20 then raise exception 'Quantidade deve ficar entre 1 e 20.'; end if;

    select name, price_cents, stock_quantity, active
    into v_name, v_price, v_stock, v_active
    from public.products where id = v_product_id for update;
    if not found or v_active is not true or v_stock < v_qty then
      raise exception 'Produto indisponível ou estoque insuficiente: %.', coalesce(v_name, 'produto');
    end if;

    if v_item ? 'accompaniments_by_unit' then
      v_sides_by_unit := v_item->'accompaniments_by_unit';
    else
      v_sides_by_unit := '[]'::jsonb;
      for v_unit_index in 1..v_qty loop
        v_sides_by_unit := v_sides_by_unit || jsonb_build_array(coalesce(v_item->'accompaniments', '[]'::jsonb));
      end loop;
    end if;
    if coalesce(jsonb_typeof(v_sides_by_unit), '') <> 'array'
       or jsonb_array_length(v_sides_by_unit) <> v_qty then
      raise exception 'As escolhas de acompanhamento não correspondem à quantidade de pratos de %.', v_name;
    end if;

    for v_unit_index in 1..v_qty loop
      v_unit_sides := v_sides_by_unit->(v_unit_index - 1);
      if coalesce(jsonb_typeof(v_unit_sides), '') <> 'array' then raise exception 'As escolhas de acompanhamento estão inválidas.'; end if;
      v_side_count := jsonb_array_length(v_unit_sides);
      if v_side_count > 2 then raise exception 'Escolha no máximo 2 acompanhamentos por prato.'; end if;
      if exists(select 1 from jsonb_array_elements(v_unit_sides) s where jsonb_typeof(s) <> 'string') then
        raise exception 'Acompanhamento inválido.';
      end if;
      if (select count(distinct value) from jsonb_array_elements_text(v_unit_sides)) <> v_side_count then
        raise exception 'Acompanhamento repetido.';
      end if;
      for v_side in select value from jsonb_array_elements_text(v_unit_sides) loop
        if not exists (
          select 1 from public.product_accompaniments pa
          where pa.product_id = v_product_id and pa.active = true and pa.name = v_side
        ) then raise exception 'Acompanhamento não disponível para %: %.', v_name, v_side; end if;
      end loop;
    end loop;

    v_total := v_total + (v_price * v_qty);
    if v_total > 10000000 then raise exception 'Total excede o limite permitido.'; end if;
  end loop;

  -- APROVADO no INSERT aciona enqueue_delivery_print_job() e cria print_jobs automaticamente.
  insert into public.orders(
    order_type, status, table_id, dining_tab_id, customer_name,
    payment_method, total_cents, needs_change, change_for_cents,
    customer_notes, approved_at, approved_by, order_source
  )
  values(
    'SALAO', 'APROVADO', v_table_id, v_tab_id, null,
    'PAGAMENTO_NA_SAIDA', v_total, false, null,
    nullif(trim(coalesce(p_customer_notes, '')), ''), now(), null, 'CLIENT_QR'
  )
  returning id, order_number into v_order_id, v_order_number;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    if v_item ? 'accompaniments_by_unit' then
      v_sides_by_unit := v_item->'accompaniments_by_unit';
    else
      v_sides_by_unit := '[]'::jsonb;
      for v_unit_index in 1..v_qty loop
        v_sides_by_unit := v_sides_by_unit || jsonb_build_array(coalesce(v_item->'accompaniments', '[]'::jsonb));
      end loop;
    end if;

    select name, price_cents into v_name, v_price from public.products where id = v_product_id;
    v_notes := nullif(trim(coalesce(v_item->>'notes', '')), '');
    if length(coalesce(v_notes, '')) > 200 then raise exception 'Observação do item deve ter até 200 caracteres.'; end if;

    insert into public.order_items(order_id, product_id, product_name_snapshot, unit_price_cents, quantity, notes)
    values(v_order_id, v_product_id, v_name, v_price, v_qty, v_notes)
    returning id into v_order_item_id;

    for v_unit_index in 1..v_qty loop
      v_unit_sides := v_sides_by_unit->(v_unit_index - 1);
      for v_side in select value from jsonb_array_elements_text(v_unit_sides) loop
        insert into public.order_item_accompaniments(order_item_id, accompaniment_name, unit_index)
        values(v_order_item_id, v_side, v_unit_index);
      end loop;
    end loop;

    update public.products set stock_quantity = stock_quantity - v_qty, updated_at = now()
    where id = v_product_id;
  end loop;

  return jsonb_build_object(
    'order_id', v_order_id, 'order_number', v_order_number,
    'table_number', v_number, 'total_cents', v_total,
    'status', 'APROVADO', 'print_queued', true
  );
end;
$$;
revoke all on function public.create_salon_qr_order(uuid, jsonb, text) from public;
grant execute on function public.create_salon_qr_order(uuid, jsonb, text) to anon, authenticated;

-- Impressão do fechamento diário pela mesma fila confiável do APK.
alter table public.print_jobs
  add column if not exists report_date date;

alter table public.print_jobs drop constraint if exists print_jobs_job_type_check;
alter table public.print_jobs add constraint print_jobs_job_type_check
  check (job_type in ('ORDER','TAB_CLOSE','DAILY_CLOSE'));

alter table public.print_jobs drop constraint if exists print_jobs_payload_check;
alter table public.print_jobs add constraint print_jobs_payload_check check (
  (job_type='ORDER' and order_id is not null and dining_tab_id is null and report_date is null)
  or (job_type='TAB_CLOSE' and order_id is null and dining_tab_id is not null and report_date is null)
  or (job_type='DAILY_CLOSE' and order_id is null and dining_tab_id is null and report_date is not null)
);

create unique index if not exists print_jobs_daily_close_unique
  on public.print_jobs(report_date) where job_type='DAILY_CLOSE';

create index if not exists dining_tabs_closed_at_cash_close_idx
  on public.dining_tabs(closed_at) where status='CLOSED';

create or replace function public.notify_printer_queue_realtime()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.status='PENDENTE' and (tg_op='INSERT' or old.status is distinct from new.status) then
    perform realtime.send('{}'::jsonb,'queue_changed','printer-queue',false);
  end if;
  return new;
end;
$;
-- Trigger-only function: keep execution unavailable to API roles.
revoke all on function public.notify_printer_queue_realtime() from public, anon, authenticated;

-- Ativa eventos Postgres Changes usados pela tela do funcionário para atualizar a comanda.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename='orders'
    ) then
      alter publication supabase_realtime add table public.orders;
    end if;
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename='dining_tabs'
    ) then
      alter publication supabase_realtime add table public.dining_tabs;
    end if;
  end if;
end;
$$;


-- Harden payment validation: SQL NULL must not bypass the allowed-method check.
-- Keep the existing role checks, row lock, idempotent close and TAB_CLOSE queue behavior.
create or replace function public.close_dining_tab_with_payment(
  p_tab_id uuid,
  p_payment_method text,
  p_closing_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $close$
declare
  v_total bigint;
  v_status text;
  v_table_id uuid;
  v_table_number integer;
  v_job uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'É necessário entrar com uma conta autorizada.';
  end if;

  if not (private.is_active_admin() or private.has_staff_role('SALON')) then
    raise exception 'Acesso restrito à equipe do salão.';
  end if;

  if p_payment_method is null or p_payment_method not in ('DINHEIRO', 'PIX', 'CARTAO') then
    raise exception 'Selecione uma forma de pagamento válida.';
  end if;

  if length(coalesce(p_closing_note, '')) > 300 then
    raise exception 'Observação deve ter até 300 caracteres.';
  end if;

  select status, table_id
    into v_status, v_table_id
    from public.dining_tabs
   where id = p_tab_id
   for update;

  if not found then
    raise exception 'Comanda não encontrada.';
  end if;

  if v_status = 'CLOSED' then
    select id into v_job
      from public.print_jobs
     where dining_tab_id = p_tab_id and job_type = 'TAB_CLOSE';
    select paid_total_cents into v_total
      from public.dining_tabs where id = p_tab_id;
    return jsonb_build_object(
      'tab_id', p_tab_id,
      'total_cents', coalesce(v_total, 0),
      'already_closed', true,
      'print_job_id', v_job
    );
  end if;

  if exists (
    select 1 from public.orders
     where dining_tab_id = p_tab_id
       and status in ('RECEBIDO'::public.order_status, 'AGUARDANDO_APROVACAO'::public.order_status)
  ) then
    raise exception 'Há pedidos aguardando aceite ou recusa. Resolva-os antes de fechar a conta.';
  end if;

  select coalesce(sum(total_cents), 0)
    into v_total
    from public.orders
   where dining_tab_id = p_tab_id
     and status <> 'CANCELADO'::public.order_status;

  select table_number into v_table_number
    from public.restaurant_tables where id = v_table_id;

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

  insert into public.print_jobs(job_type, dining_tab_id, status, attempt_count, next_attempt_at)
  values ('TAB_CLOSE', p_tab_id, 'PENDENTE', 0, now())
  on conflict (dining_tab_id) where job_type = 'TAB_CLOSE' do nothing
  returning id into v_job;

  if v_job is null then
    select id into v_job
      from public.print_jobs
     where dining_tab_id = p_tab_id and job_type = 'TAB_CLOSE';
  end if;

  return jsonb_build_object(
    'tab_id', p_tab_id,
    'table_number', v_table_number,
    'total_cents', v_total,
    'payment_method', p_payment_method,
    'print_job_id', v_job,
    'print_queued', true
  );
end;
$close$;
