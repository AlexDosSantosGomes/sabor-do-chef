create or replace function public.get_salon_qr_context(p_qr_token uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_table_id uuid; v_number integer; v_tab_id uuid;
begin
 select id,table_number into v_table_id,v_number from public.restaurant_tables where qr_token=p_qr_token and active=true;
 if not found then raise exception 'QR Code inválido ou mesa desativada.'; end if;
 select id into v_tab_id from public.dining_tabs where table_id=v_table_id and status='OPEN' limit 1;
 return jsonb_build_object('table_number',v_number,'has_open_tab',v_tab_id is not null);
end; $$;
revoke all on function public.get_salon_qr_context(uuid) from public;
grant execute on function public.get_salon_qr_context(uuid) to anon,authenticated;

create or replace function public.create_salon_qr_order(p_qr_token uuid,p_items jsonb,p_customer_notes text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_table_id uuid; v_tab_id uuid; v_number integer; v_item jsonb; v_product_id uuid; v_qty integer; v_name text; v_price integer; v_stock integer; v_active boolean; v_total integer:=0; v_order_id uuid; v_order_number bigint; v_item_id uuid; v_notes text;
begin
 select id,table_number into v_table_id,v_number from public.restaurant_tables where qr_token=p_qr_token and active=true;
 if not found then raise exception 'QR Code inválido ou mesa desativada.'; end if;
 select id into v_tab_id from public.dining_tabs where table_id=v_table_id and status='OPEN' for update;
 if v_tab_id is null then raise exception 'A mesa ainda não está recebendo pedidos. Chame um funcionário.'; end if;
 if length(trim(coalesce(p_customer_notes,'')))>300 then raise exception 'Observação deve ter até 300 caracteres.'; end if;
 if coalesce(jsonb_typeof(p_items),'')<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>30 then raise exception 'Adicione entre 1 e 30 produtos.'; end if;
 if (select count(distinct (x->>'product_id')::uuid) from jsonb_array_elements(p_items) x)<>jsonb_array_length(p_items) then raise exception 'Há produtos repetidos no carrinho.'; end if;
 for v_item in select value from jsonb_array_elements(p_items) order by (value->>'product_id')::uuid loop
  if coalesce(v_item->>'quantity','') !~ '^[0-9]+$' then raise exception 'Quantidade inválida.'; end if;
  v_product_id:=(v_item->>'product_id')::uuid;v_qty:=(v_item->>'quantity')::integer;
  if v_qty<1 or v_qty>20 then raise exception 'Quantidade deve ficar entre 1 e 20.'; end if;
  select name,price_cents,stock_quantity,active into v_name,v_price,v_stock,v_active from public.products where id=v_product_id for update;
  if not found or v_active is not true then raise exception 'Produto indisponível.'; end if;
  if v_stock<v_qty then raise exception 'Estoque insuficiente para: %.',v_name; end if;
  v_total:=v_total+(v_price*v_qty);if v_total>10000000 then raise exception 'Total excede o limite permitido.';end if;
 end loop;
 insert into public.orders(order_type,status,table_id,dining_tab_id,customer_name,payment_method,total_cents,needs_change,change_for_cents,customer_notes)
 values('SALAO','RECEBIDO',v_table_id,v_tab_id,null,'PAGAMENTO_NA_SAIDA',v_total,false,null,nullif(trim(coalesce(p_customer_notes,'')),''))
 returning id,order_number into v_order_id,v_order_number;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_product_id:=(v_item->>'product_id')::uuid;v_qty:=(v_item->>'quantity')::integer;
  select name,price_cents into v_name,v_price from public.products where id=v_product_id;
  v_notes:=nullif(trim(coalesce(v_item->>'notes','')),'');
  if length(coalesce(v_notes,''))>200 then raise exception 'Observação do item deve ter até 200 caracteres.';end if;
  insert into public.order_items(order_id,product_id,product_name_snapshot,unit_price_cents,quantity,notes) values(v_order_id,v_product_id,v_name,v_price,v_qty,v_notes) returning id into v_item_id;
  update public.products set stock_quantity=stock_quantity-v_qty,updated_at=now() where id=v_product_id;
 end loop;
 return jsonb_build_object('order_id',v_order_id,'order_number',v_order_number,'table_number',v_number,'total_cents',v_total);
end; $$;
revoke all on function public.create_salon_qr_order(uuid,jsonb,text) from public;
grant execute on function public.create_salon_qr_order(uuid,jsonb,text) to anon,authenticated;