ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS dining_tab_id uuid
  REFERENCES public.dining_tabs(id);
CREATE INDEX IF NOT EXISTS orders_dining_tab_id_idx
  ON public.orders (dining_tab_id)
  WHERE dining_tab_id IS NOT NULL;

DROP POLICY IF EXISTS dining_tabs_salon_insert ON public.dining_tabs;
DROP POLICY IF EXISTS dining_tabs_salon_update ON public.dining_tabs;

CREATE OR REPLACE FUNCTION public.open_dining_tab(p_table_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tab_id uuid;
BEGIN
  IF (select auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'É necessário entrar com uma conta autorizada.';
  END IF;
  IF NOT (private.is_active_admin() OR private.has_staff_role('SALON')) THEN
    RAISE EXCEPTION 'Acesso restrito à equipe do salão.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.restaurant_tables
    WHERE id = p_table_id AND active = true
  ) THEN
    RAISE EXCEPTION 'Mesa inexistente ou inativa.';
  END IF;
  INSERT INTO public.dining_tabs (table_id, status, opened_by)
  VALUES (p_table_id, 'OPEN', (select auth.uid()))
  RETURNING id INTO v_tab_id;
  RETURN v_tab_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Esta mesa já possui uma comanda aberta.';
END;
$$;

CREATE OR REPLACE FUNCTION public.close_dining_tab(
  p_tab_id uuid,
  p_closing_note text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_updated integer;
BEGIN
  IF (select auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'É necessário entrar com uma conta autorizada.';
  END IF;
  IF NOT (private.is_active_admin() OR private.has_staff_role('SALON')) THEN
    RAISE EXCEPTION 'Acesso restrito à equipe do salão.';
  END IF;
  IF length(coalesce(p_closing_note, '')) > 300 THEN
    RAISE EXCEPTION 'A observação de fechamento deve ter até 300 caracteres.';
  END IF;
  UPDATE public.dining_tabs
     SET status = 'CLOSED',
         closed_by = (select auth.uid()),
         closed_at = now(),
         closing_note = nullif(trim(coalesce(p_closing_note, '')), '')
   WHERE id = p_tab_id AND status = 'OPEN';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RAISE EXCEPTION 'Comanda não encontrada ou já está fechada.';
  END IF;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.open_dining_tab(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.close_dining_tab(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_dining_tab(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_dining_tab(uuid, text) TO authenticated;
