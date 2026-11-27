-- Salão: pedidos independentes por cliente, sem dependência de comanda compartilhada.
-- Mantém dining_tabs apenas para histórico; novos pedidos usam dining_tab_id = NULL.
begin;

alter table public.orders
  add column if not exists client_request_id uuid,
  add column if not exists payment_status text,
  add column if not exists paid_payment_method text,
  add column if not exists paid_at timestamptz,
  add column if not exists paid_by uuid references auth.users(id);

create unique index if not exists orders_client_request_id_uidx
  on public.orders(client_request_id) where client_request_id is not null;

alter table public.orders drop constraint if exists orders_payment_status_check;
alter table public.orders add constraint orders_payment_status_check
  check (
    (order_type = 'SALAO'::public.order_type and payment_status in ('PENDENTE','PAGO'))
    or (order_type <> 'SALAO'::public.order_type and payment_status is null)
  );

alter table public.orders drop constraint if exists orders_paid_payment_method_check;
alter table public.orders add constraint orders_paid_payment_method_check
  check (paid_payment_method is null or paid_payment_method in ('CASH','PIX','CARD'));

alter table public.orders drop constraint if exists orders_paid_fields_check;
alter table public.orders add constraint orders_paid_fields_check
  check (
    (payment_status = 'PAGO' and paid_payment_method is not null and paid_at is not null)
    or (payment_status = 'PENDENTE' and paid_payment_method is null and paid_at is null and paid_by is null)
    or (payment_status is null)
  );

-- Migra o estado financeiro das comandas antigas sem apagar seu histórico.
update public.orders o
set payment_status = case when dt.status = 'CLOSED' then 'PAGO' else 'PENDENTE' end,
    paid_payment_method = case
      when dt.status = 'CLOSED' then case upper(coalesce(dt.payment_method,'')) 
        when 'DINHEIRO' then 'CASH' when 'CASH' then 'CASH'
        when 'PIX' then 'PIX' when 'CARTAO' then 'CARD' when 'CARD' then 'CARD'
        else null end
      else null end,
    paid_at = case when dt.status = 'CLOSED' then dt.closed_at else null end,
    paid_by = case when dt.status = 'CLOSED' then dt.closed_by else null end
from public.dining_tabs dt
where o.order_type = 'SALAO'::public.order_type
  and o.dining_tab_id = dt.id
  and o.payment_status is null;

-- Permite nome obrigatório nos novos pedidos do salão e preserva pedidos antigos
-- vinculados a comandas históricas que ainda não tinham nome individual.
alter table public.orders drop constraint if exists order_destination_check;
alter table public.orders add constraint order_destination_check check (
  (
    order_type = 'SALAO'::public.order_type
    and table_id is not null
    and (customer_name is not null or dining_tab_id is not null)
  )
  or (
    order_type = 'DELIVERY'::public.order_type
    and table_id is null and customer_name is not null
    and customer_phone is not null and delivery_address is not null
  )
  or (
    order_type = 'PICKUP'::public.order_type
    and table_id is null and customer_name is not null
    and customer_phone is not null and delivery_address is null
  )
);

create index if not exists orders_salon_payment_pending_idx
  on public.orders(created_at desc)
  where order_type = 'SALAO'::public.order_type and payment_status = 'PENDENTE';

create or replace function private.create_salon_individual_order(
  p_table_id uuid,
  p_customer_name text,
  p_payment_method text,
  p_needs_change boolean,
  p_change_for_cents integer,
  p_items jsonb,
  p_customer_notes text,
  p_request_id uuid,
  p_source text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $fn$
declare
  v_item jsonb;
  v_product_id uuid;
  v_qty integer;
  v_name text;
  v_price integer;
  v_stock integer;
  v_active boolean;
  v_total integer := 0;
  v_order_id uuid;
  v_order_number bigint;
  v_order_item_id uuid;
  v_notes text;
  v_sides_by_unit jsonb;
  v_unit_sides jsonb;
  v_side text;
  v_side_count integer;
  v_unit_index integer;
  v_existing public.orders%rowtype;
begin
  if p_source not in ('CLIENT_QR','STAFF') then
    raise exception 'Origem de pedido inválida.';
  end if;
  if p_source = 'STAFF' and (
    (select auth.uid()) is null
    or not (private.is_active_admin() or private.has_staff_role('SALON'))
  ) then
    raise exception 'Acesso restrito à equipe do salão.';
  end if;
  if p_table_id is null or not exists (
    select 1 from public.restaurant_tables
    where id = p_table_id and active = true
  ) then
    raise exception 'Mesa inválida ou desativada.';
  end if;
  if p_customer_name is null or length(trim(p_customer_name)) < 2
     or length(trim(p_customer_name)) > 100 then
    raise exception 'Informe o nome do cliente (2 a 100 caracteres).';
  end if;
  if p_payment_method is null or p_payment_method not in ('CASH','PIX','CARD') then
    raise exception 'Selecione Dinheiro, Pix ou Cartão.';
  end if;
  if p_request_id is null then
    raise exception 'Identificador de envio ausente. Atualize a página e tente novamente.';
  end if;
  if length(coalesce(p_customer_notes,'')) > 300 then
    raise exception 'A observação deve ter até 300 caracteres.';
  end if;

  -- Reenvio do mesmo identificador devolve o pedido já criado, sem duplicar estoque ou impressão.
  select * into v_existing from public.orders where client_request_id = p_request_id;
  if found then
    if v_existing.order_type <> 'SALAO'::public.order_type or v_existing.table_id <> p_table_id then
      raise exception 'Identificador de pedido já utilizado.';
    end if;
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'table_id', v_existing.table_id,
      'total_cents', v_existing.total_cents,
      'status', v_existing.status,
      'already_created', true,
      'print_queued', true
    );
  end if;

  if coalesce(jsonb_typeof(p_items),'') <> 'array'
     or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 30 then
    raise exception 'Adicione entre 1 e 30 produtos.';
  end if;
  if (select count(distinct (x->>'product_id')::uuid)
      from jsonb_array_elements(p_items) x) <> jsonb_array_length(p_items) then
    raise exception 'Há produtos repetidos no pedido.';
  end if;

  for v_item in
    select value from jsonb_array_elements(p_items)
    order by (value->>'product_id')::uuid
  loop
    if coalesce(v_item->>'quantity','') !~ '^[0-9]+$' then
      raise exception 'Quantidade inválida.';
    end if;
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty < 1 or v_qty > 20 then raise exception 'Quantidade deve ficar entre 1 e 20.'; end if;

    select name, price_cents, stock_quantity, active
      into v_name, v_price, v_stock, v_active
      from public.products where id = v_product_id for update;
    if not found or v_active is not true or v_stock < v_qty then
      raise exception 'Produto indisponível ou estoque insuficiente: %.', coalesce(v_name,'produto');
    end if;

    if v_item ? 'accompaniments_by_unit' then
      v_sides_by_unit := v_item->'accompaniments_by_unit';
    else
      v_sides_by_unit := '[]'::jsonb;
      for v_unit_index in 1..v_qty loop
        v_sides_by_unit := v_sides_by_unit || jsonb_build_array(coalesce(v_item->'accompaniments','[]'::jsonb));
      end loop;
    end if;
    if coalesce(jsonb_typeof(v_sides_by_unit),'') <> 'array'
       or jsonb_array_length(v_sides_by_unit) <> v_qty then
      raise exception 'As escolhas de acompanhamento não correspondem à quantidade de %.', v_name;
    end if;

    for v_unit_index in 1..v_qty loop
      v_unit_sides := v_sides_by_unit->(v_unit_index - 1);
      if coalesce(jsonb_typeof(v_unit_sides),'') <> 'array' then
        raise exception 'Escolhas de acompanhamento inválidas.';
      end if;
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
        ) then
          raise exception 'Acompanhamento não disponível para %: %.', v_name, v_side;
        end if;
      end loop;
    end loop;

    v_total := v_total + (v_price * v_qty);
    if v_total > 10000000 then raise exception 'Total excede o limite permitido.'; end if;
  end loop;

  if coalesce(p_needs_change,false) then
    if p_payment_method <> 'CASH' or p_change_for_cents is null or p_change_for_cents <= v_total then
      raise exception 'Para informar troco, escolha Dinheiro e informe um valor maior que o total.';
    end if;
  elsif p_change_for_cents is not null then
    raise exception 'Valor de troco não deve ser enviado quando não solicitado.';
  end if;

  insert into public.orders(
    order_type,status,table_id,dining_tab_id,customer_name,payment_method,
    total_cents,needs_change,change_for_cents,customer_notes,approved_at,
    order_source,client_request_id,payment_status
  ) values (
    'SALAO','APROVADO',p_table_id,null,trim(p_customer_name),p_payment_method,
    v_total,coalesce(p_needs_change,false),
    case when coalesce(p_needs_change,false) then p_change_for_cents else null end,
    nullif(trim(coalesce(p_customer_notes,'')),''),now(),
    p_source,p_request_id,'PENDENTE'
  ) returning id,order_number into v_order_id,v_order_number;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    if v_item ? 'accompaniments_by_unit' then
      v_sides_by_unit := v_item->'accompaniments_by_unit';
    else
      v_sides_by_unit := '[]'::jsonb;
      for v_unit_index in 1..v_qty loop
        v_sides_by_unit := v_sides_by_unit || jsonb_build_array(coalesce(v_item->'accompaniments','[]'::jsonb));
      end loop;
    end if;

    select name,price_cents into v_name,v_price from public.products where id=v_product_id;
    v_notes := nullif(trim(coalesce(v_item->>'notes','')),'');
    if length(coalesce(v_notes,'')) > 200 then raise exception 'Observação do item deve ter até 200 caracteres.'; end if;

    insert into public.order_items(order_id,product_id,product_name_snapshot,unit_price_cents,quantity,notes)
    values(v_order_id,v_product_id,v_name,v_price,v_qty,v_notes)
    returning id into v_order_item_id;

    for v_unit_index in 1..v_qty loop
      v_unit_sides := v_sides_by_unit->(v_unit_index - 1);
      for v_side in select value from jsonb_array_elements_text(v_unit_sides) loop
        insert into public.order_item_accompaniments(order_item_id,accompaniment_name,unit_index)
        values(v_order_item_id,v_side,v_unit_index);
      end loop;
    end loop;

    update public.products set stock_quantity=stock_quantity-v_qty,updated_at=now()
    where id=v_product_id;
  end loop;

  return jsonb_build_object(
    'order_id',v_order_id,'order_number',v_order_number,'table_id',p_table_id,
    'total_cents',v_total,'status','APROVADO','payment_status','PENDENTE','print_queued',true
  );
end;
$fn$;
revoke all on function private.create_salon_individual_order(uuid,text,text,boolean,integer,jsonb,text,uuid,text) from public,anon,authenticated;

create or replace function public.create_salon_qr_individual_order(
  p_qr_token uuid,p_customer_name text,p_payment_method text,
  p_needs_change boolean,p_change_for_cents integer,p_items jsonb,
  p_customer_notes text,p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $qr$
declare v_table_id uuid;
begin
  select id into v_table_id from public.restaurant_tables
  where qr_token=p_qr_token and active=true;
  if not found then raise exception 'QR Code inválido ou mesa desativada.'; end if;
  return private.create_salon_individual_order(
    v_table_id,p_customer_name,p_payment_method,p_needs_change,p_change_for_cents,
    p_items,p_customer_notes,p_request_id,'CLIENT_QR'
  );
end;
$qr$;
revoke all on function public.create_salon_qr_individual_order(uuid,text,text,boolean,integer,jsonb,text,uuid) from public;
grant execute on function public.create_salon_qr_individual_order(uuid,text,text,boolean,integer,jsonb,text,uuid) to anon,authenticated;

create or replace function public.create_salon_staff_individual_order(
  p_table_id uuid,p_customer_name text,p_payment_method text,
  p_needs_change boolean,p_change_for_cents integer,p_items jsonb,
  p_customer_notes text,p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $staff$
begin
  if (select auth.uid()) is null
     or not (private.is_active_admin() or private.has_staff_role('SALON')) then
    raise exception 'Acesso restrito à equipe do salão.';
  end if;
  return private.create_salon_individual_order(
    p_table_id,p_customer_name,p_payment_method,p_needs_change,p_change_for_cents,
    p_items,p_customer_notes,p_request_id,'STAFF'
  );
end;
$staff$;
revoke all on function public.create_salon_staff_individual_order(uuid,text,text,boolean,integer,jsonb,text,uuid) from public,anon;
grant execute on function public.create_salon_staff_individual_order(uuid,text,text,boolean,integer,jsonb,text,uuid) to authenticated;

create or replace function public.settle_salon_order_payment(
  p_order_id uuid,p_payment_method text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $pay$
declare v_order public.orders%rowtype;
begin
  if (select auth.uid()) is null
     or not (private.is_active_admin() or private.has_staff_role('SALON')) then
    raise exception 'Acesso restrito ao caixa.';
  end if;
  if p_payment_method is null or p_payment_method not in ('CASH','PIX','CARD') then
    raise exception 'Selecione uma forma de pagamento válida.';
  end if;
  select * into v_order from public.orders
  where id=p_order_id and order_type='SALAO'::public.order_type
  for update;
  if not found then raise exception 'Pedido do salão não encontrado.'; end if;
  if v_order.payment_status='PAGO' then
    return jsonb_build_object('order_id',v_order.id,'order_number',v_order.order_number,
      'payment_status','PAGO','paid_payment_method',v_order.paid_payment_method,'already_paid',true);
  end if;
  if v_order.status='CANCELADO' then raise exception 'Pedido cancelado não pode ser recebido.'; end if;
  update public.orders set payment_status='PAGO',paid_payment_method=p_payment_method,
    paid_at=now(),paid_by=(select auth.uid())
  where id=p_order_id;
  return jsonb_build_object('order_id',p_order_id,'order_number',v_order.order_number,
    'payment_status','PAGO','paid_payment_method',p_payment_method,'paid_at',now());
end;
$pay$;
revoke all on function public.settle_salon_order_payment(uuid,text) from public,anon;
grant execute on function public.settle_salon_order_payment(uuid,text) to authenticated;

commit;
