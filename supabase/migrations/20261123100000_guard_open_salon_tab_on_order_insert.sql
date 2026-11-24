-- Prevent a staff order from racing with the closing of its dining tab.
-- The row lock serializes order insertion with close_dining_tab_with_payment().
create or replace function public.ensure_salon_order_tab_is_open()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $guard$
declare
  v_status text;
  v_active boolean;
begin
  if new.order_type = 'SALAO'::public.order_type then
    select dt.status, rt.active
      into v_status, v_active
      from public.dining_tabs dt
      join public.restaurant_tables rt on rt.id = dt.table_id
     where dt.id = new.dining_tab_id
     for update of dt;

    if not found or v_status <> 'OPEN' or v_active is not true then
      raise exception 'Comanda fechada ou mesa inativa. Atualize a tela e tente novamente.';
    end if;
  end if;
  return new;
end;
$guard$;

drop trigger if exists orders_guard_open_salon_tab on public.orders;
create trigger orders_guard_open_salon_tab
before insert on public.orders
for each row
when (new.order_type = 'SALAO'::public.order_type)
execute function public.ensure_salon_order_tab_is_open();
