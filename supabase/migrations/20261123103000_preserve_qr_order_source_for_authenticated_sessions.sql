-- Preserve CLIENT_QR when the public QR RPC is called from an authenticated Supabase session.
-- Staff RPCs rely on the column default STAFF; the CHECK constraint limits valid values.
create or replace function public.mark_salon_order_source()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $source$
begin
  if new.order_type = 'SALAO'::public.order_type
     and new.order_source not in ('CLIENT_QR', 'STAFF') then
    new.order_source := 'STAFF';
  end if;
  return new;
end;
$source$;
