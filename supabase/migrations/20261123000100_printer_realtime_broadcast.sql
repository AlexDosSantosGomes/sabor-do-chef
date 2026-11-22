-- Generic Realtime wake-up signal for the Android printer.
-- No order IDs, customer data, or print-job fields are exposed in the public broadcast.
-- The device still claims and acknowledges jobs only through printer-device-api.
CREATE OR REPLACE FUNCTION public.notify_printer_queue_realtime()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'PENDENTE'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    PERFORM realtime.send(
      '{}'::jsonb,
      'queue_changed',
      'printer-queue',
      false
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS print_jobs_realtime_wakeup ON public.print_jobs;
CREATE TRIGGER print_jobs_realtime_wakeup
AFTER INSERT OR UPDATE OF status ON public.print_jobs
FOR EACH ROW
EXECUTE FUNCTION public.notify_printer_queue_realtime();

COMMENT ON FUNCTION public.notify_printer_queue_realtime() IS
'Emits an empty public Realtime signal when a print job becomes pending; job data remains protected by printer-device-api and existing RLS.';
