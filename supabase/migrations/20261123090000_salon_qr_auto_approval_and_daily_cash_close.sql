-- QR do Salão: pedidos do cliente são aprovados automaticamente e entram na fila existente.
-- Preserva validações de estoque, acompanhamentos por unidade e limite de 2 acompanhamentos.
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
    customer_notes, approved_at, approved_by
  )
  values(
    'SALAO', 'APROVADO', v_table_id, v_tab_id, null,
    'PAGAMENTO_NA_SAIDA', v_total, false, null,
    nullif(trim(coalesce(p_customer_notes, '')), ''), now(), null
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
$$;
