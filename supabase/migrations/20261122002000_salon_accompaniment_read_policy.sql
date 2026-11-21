drop policy if exists order_item_accompaniments_salon_read on public.order_item_accompaniments;
create policy order_item_accompaniments_salon_read
on public.order_item_accompaniments
for select
to authenticated
using (
  exists (
    select 1
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where oi.id = order_item_accompaniments.order_item_id
       and o.order_type = 'SALAO'::public.order_type
       and private.has_staff_role('SALON')
  )
);
