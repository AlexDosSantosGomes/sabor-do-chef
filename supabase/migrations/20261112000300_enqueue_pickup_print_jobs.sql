-- Enqueue approved pickup orders in the same existing print queue.
-- Delivery behavior remains unchanged and duplicate jobs remain prevented by the existing constraint.
CREATE OR REPLACE FUNCTION public.enqueue_delivery_print_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF new.order_type IN ('DELIVERY'::public.order_type, 'PICKUP'::public.order_type)
     AND new.status = 'APROVADO'::public.order_status
     AND (tg_op = 'INSERT' OR old.status IS DISTINCT FROM new.status) THEN
    INSERT INTO public.print_jobs (order_id, status)
    VALUES (new.id, 'PENDENTE'::public.print_status)
    ON CONFLICT (order_id) DO NOTHING;
  END IF;
  RETURN new;
END;
$$;
