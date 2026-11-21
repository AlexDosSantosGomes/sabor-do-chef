-- Delivery employee read access and guarded order actions.
drop policy if exists orders_delivery_read on public.orders;
create policy orders_delivery_read on public.orders
for select to authenticated
using (order_type in ('DELIVERY'::public.order_type,'PICKUP'::public.order_type) and private.has_staff_role('DELIVERY'));

drop policy if exists order_items_delivery_read on public.order_items;
create policy order_items_delivery_read on public.order_items
for select to authenticated
using (exists (select 1 from public.orders o where o.id=order_items.order_id and o.order_type in ('DELIVERY'::public.order_type,'PICKUP'::public.order_type) and private.has_staff_role('DELIVERY')));

create or replace function public.set_delivery_order_action(p_order_id uuid,p_action text,p_reason text default null)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare v_status public.order_status; v_type public.order_type;
begin
 if (select auth.uid()) is null then raise exception 'É necessário entrar com uma conta autorizada.'; end if;
 if not (private.is_active_admin() or private.has_staff_role('DELIVERY')) then raise exception 'Acesso restrito à equipe de entrega.'; end if;
 select order_type,status into v_type,v_status from public.orders where id=p_order_id for update;
 if not found then raise exception 'Pedido não encontrado.'; end if;
 if v_type not in ('DELIVERY'::public.order_type,'PICKUP'::public.order_type) then raise exception 'Este pedido não pertence à entrega ou retirada.'; end if;
 if p_action='APPROVE' then
  if v_status not in ('RECEBIDO'::public.order_status,'AGUARDANDO_APROVACAO'::public.order_status) then raise exception 'Este pedido não está aguardando aprovação.'; end if;
  update public.orders set status='APROVADO',approved_by=case when private.is_active_admin() then (select auth.uid()) else null end,approved_at=now(),cancellation_reason=null,cancelled_at=null where id=p_order_id;
 elsif p_action='REJECT' then
  if v_status not in ('RECEBIDO'::public.order_status,'AGUARDANDO_APROVACAO'::public.order_status) then raise exception 'Somente pedidos aguardando aprovação podem ser recusados.'; end if;
  if length(trim(coalesce(p_reason,'')))<3 or length(p_reason)>300 then raise exception 'Informe o motivo da recusa (3 a 300 caracteres).'; end if;
  update public.orders set status='CANCELADO',cancellation_reason=trim(p_reason),cancelled_at=now() where id=p_order_id;
 elsif p_action='DELIVER' then
  if v_status not in ('APROVADO'::public.order_status,'ENVIADO_IMPRESSAO'::public.order_status,'IMPRESSO'::public.order_status,'FALHA_IMPRESSAO'::public.order_status) then raise exception 'Somente pedidos aprovados podem ser marcados como entregues.'; end if;
  update public.orders set status='ENTREGUE' where id=p_order_id;
 else raise exception 'Ação inválida.';
 end if;
 return true;
end; $$;
revoke all on function public.set_delivery_order_action(uuid,text,text) from public;
revoke all on function public.set_delivery_order_action(uuid,text,text) from anon;
grant execute on function public.set_delivery_order_action(uuid,text,text) to authenticated;