ALTER TABLE public.print_jobs
  ALTER COLUMN order_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS job_type text NOT NULL DEFAULT 'ORDER',
  ADD COLUMN IF NOT EXISTS dining_tab_id uuid REFERENCES public.dining_tabs(id);
ALTER TABLE public.print_jobs ADD CONSTRAINT print_jobs_job_type_check CHECK (job_type IN ('ORDER','TAB_CLOSE'));
ALTER TABLE public.print_jobs ADD CONSTRAINT print_jobs_payload_check CHECK (
 (job_type='ORDER' AND order_id IS NOT NULL AND dining_tab_id IS NULL)
 OR (job_type='TAB_CLOSE' AND order_id IS NULL AND dining_tab_id IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS print_jobs_tab_close_unique ON public.print_jobs(dining_tab_id) WHERE job_type='TAB_CLOSE';
CREATE INDEX IF NOT EXISTS print_jobs_pending_queue_idx ON public.print_jobs(status,next_attempt_at,created_at);

CREATE OR REPLACE FUNCTION public.notify_printer_queue_realtime()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $trigger$
BEGIN
  IF NEW.status='PENDENTE' AND (TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    PERFORM realtime.send('{}'::jsonb,'queue_changed','printer-queue',false);
  END IF;
  RETURN NEW;
END;
$trigger$;
DROP TRIGGER IF EXISTS print_jobs_realtime_wakeup ON public.print_jobs;
CREATE TRIGGER print_jobs_realtime_wakeup
AFTER INSERT OR UPDATE OF status ON public.print_jobs
FOR EACH ROW EXECUTE FUNCTION public.notify_printer_queue_realtime();

CREATE OR REPLACE FUNCTION public.close_dining_tab_with_payment(p_tab_id uuid,p_payment_method text,p_closing_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $close$
DECLARE v_total bigint; v_status text; v_table_id uuid; v_table_number integer; v_job uuid;
BEGIN
 IF (SELECT auth.uid()) IS NULL THEN RAISE EXCEPTION 'É necessário entrar com uma conta autorizada.'; END IF;
 IF NOT (private.is_active_admin() OR private.has_staff_role('SALON')) THEN RAISE EXCEPTION 'Acesso restrito à equipe do salão.'; END IF;
 IF p_payment_method NOT IN ('DINHEIRO','PIX','CARTAO') THEN RAISE EXCEPTION 'Selecione uma forma de pagamento válida.'; END IF;
 IF length(coalesce(p_closing_note,''))>300 THEN RAISE EXCEPTION 'Observação deve ter até 300 caracteres.'; END IF;
 SELECT status,table_id INTO v_status,v_table_id FROM public.dining_tabs WHERE id=p_tab_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
 IF v_status='CLOSED' THEN
  SELECT id INTO v_job FROM public.print_jobs WHERE dining_tab_id=p_tab_id AND job_type='TAB_CLOSE';
  SELECT paid_total_cents INTO v_total FROM public.dining_tabs WHERE id=p_tab_id;
  RETURN jsonb_build_object('tab_id',p_tab_id,'total_cents',coalesce(v_total,0),'already_closed',true,'print_job_id',v_job);
 END IF;
 IF EXISTS(SELECT 1 FROM public.orders WHERE dining_tab_id=p_tab_id AND status IN ('RECEBIDO'::public.order_status,'AGUARDANDO_APROVACAO'::public.order_status)) THEN
  RAISE EXCEPTION 'Há pedidos aguardando aceite ou recusa. Resolva-os antes de fechar a conta.';
 END IF;
 SELECT coalesce(sum(total_cents),0) INTO v_total FROM public.orders WHERE dining_tab_id=p_tab_id AND status<>'CANCELADO'::public.order_status;
 SELECT table_number INTO v_table_number FROM public.restaurant_tables WHERE id=v_table_id;
 UPDATE public.dining_tabs SET status='CLOSED',closed_by=(SELECT auth.uid()),closed_at=now(),
  closing_note=nullif(trim(coalesce(p_closing_note,'')),''),payment_method=p_payment_method,paid_total_cents=v_total WHERE id=p_tab_id;
 UPDATE public.orders SET status='ENTREGUE' WHERE dining_tab_id=p_tab_id AND status IN
  ('APROVADO'::public.order_status,'ENVIADO_IMPRESSAO'::public.order_status,'IMPRESSO'::public.order_status,'FALHA_IMPRESSAO'::public.order_status);
 INSERT INTO public.print_jobs(job_type,dining_tab_id,status,attempt_count,next_attempt_at)
 VALUES('TAB_CLOSE',p_tab_id,'PENDENTE',0,now())
 ON CONFLICT (dining_tab_id) WHERE job_type='TAB_CLOSE' DO NOTHING RETURNING id INTO v_job;
 IF v_job IS NULL THEN SELECT id INTO v_job FROM public.print_jobs WHERE dining_tab_id=p_tab_id AND job_type='TAB_CLOSE'; END IF;
 RETURN jsonb_build_object('tab_id',p_tab_id,'table_number',v_table_number,'total_cents',v_total,'payment_method',p_payment_method,'print_job_id',v_job,'print_queued',true);
END; $close$;
REVOKE ALL ON FUNCTION public.close_dining_tab_with_payment(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.close_dining_tab_with_payment(uuid,text,text) TO authenticated;
