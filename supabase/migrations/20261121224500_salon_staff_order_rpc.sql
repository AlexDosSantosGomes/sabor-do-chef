-- Salon staff can add products only to an active open dining tab.
create or replace function public.create_salon_order(p_tab_id uuid,p_items jsonb,p_customer_notes text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_item jsonb; v_product_id uuid; v_qty integer; v_name text; v_price integer; v_stock integer; v_active boolean;
v_total integer:=0; v_order_id uuid; v_order_number bigint; v_order_item_id uuid; v_notes text;
begin
 if (select auth.uid()) is null then raise exception 'É necessário entrar com uma conta autorizada.'; end if;
 if not (private.is_active_admin() or private.has_staff_role('SALON')) then raise exception 'Acesso restrito à equipe do salão.'; end if;
 if length(trim(coalesce(p_customer_notes,'')))>300 then raise exception 'Observação deve ter até 300 caracteres.'; end if;
 if coalesce(jsonb_typeof(p_items),'')<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>30 then raise exception 'Adicione entre 1 e 30 produtos.'; end if;
 if not exists(select 1 from public.dining_tabs dt join public.restaurant_tables rt on rt.id=dt.table_id where dt.id=p_tab_id and dt.status='OPEN' and rt.active=true) then raise exception 'Comanda fechada ou mesa inativa.'; end if;
 if (select count(distinct (x->>'product_id')::uuid) from jsonb_array_elements(p_items) x)<>jsonb_array_length(p_items) then raise exception 'Há produtos repetidos no pedido.'; end if;
 for v_item in select value from jsonb_array_elements(p_items) order by (value->>'product_id')::uuid loop
  if coalesce(v_item->>'quantity','') !~ '^[0-9]+$' then raise exception 'Quantidade inválida.'; end if;
  v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
  if v_qty<1 or v_qty>20 then raise exception 'Quantidade deve ficar entre 1 e 20.'; end if;
  select name,price_cents,stock_quantity,active into v_name,v_price,v_stock,v_active from public.products where id=v_product_id for update;
  if not found or v_active is not true then raise exception 'Produto indisponível.'; end if;
  if v_stock<v_qty then raise exception 'Estoque insuficiente para: %.',v_name; end if;
  v_total:=v_total+(v_price*v_qty); if v_total>10000000 then raise exception 'Total excede o limite permitido.'; end if;
 end loop;
 insert into public.orders(order_type,status,table_id,dining_tab_id,customer_name,payment_method,total_cents,needs_change,change_for_cents,customer_notes)
 select 'SALAO','APROVADO',dt.table_id,p_tab_id,null,'PAGAMENTO_NA_SAIDA',v_total,false,null,nullif(trim(coalesce(p_customer_notes,'')),'')
 from public.dining_tabs dt where dt.id=p_tab_id returning id,order_number into v_order_id,v_order_number;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
  select name,price_cents into v_name,v_price from public.products where id=v_product_id;
  v_notes:=nullif(trim(coalesce(v_item->>'notes','')),'');
  if length(coalesce(v_notes,''))>200 then raise exception 'Observação do item deve ter até 200 caracteres.'; end if;
  insert into public.order_items(order_id,product_id,product_name_snapshot,unit_price_cents,quantity,notes)
  values(v_order_id,v_product_id,v_name,v_price,v_qty,v_notes) returning id into v_order_item_id;
  update public.products set stock_quantity=stock_quantity-v_qty,updated_at=now() where id=v_product_id;
 end loop;
 return jsonb_build_object('order_id',v_order_id,'order_number',v_order_number,'total_cents',v_total);
end; $$;
revoke all on function public.create_salon_order(uuid,jsonb,text) from public;
revoke all on function public.create_salon_order(uuid,jsonb,text) from anon;
grant execute on function public.create_salon_order(uuid,jsonb,text) to authenticated;