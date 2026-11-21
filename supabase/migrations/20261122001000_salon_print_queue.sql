create or replace function public.enqueue_delivery_print_job()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.order_type in (
       'DELIVERY'::public.order_type,
       'PICKUP'::public.order_type,
       'SALAO'::public.order_type
     )
     and new.status = 'APROVADO'::public.order_status
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    insert into public.print_jobs(order_id, status)
    values(new.id, 'PENDENTE'::public.print_status)
    on conflict (order_id) do nothing;
  end if;
  return new;
end;
$$;
