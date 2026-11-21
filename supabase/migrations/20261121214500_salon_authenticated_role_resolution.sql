CREATE OR REPLACE FUNCTION public.get_my_access_role()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := (select auth.uid());
  v_role text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN NULL;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.admin_profiles ap
    WHERE ap.user_id = v_uid AND ap.is_active = true
  ) THEN
    RETURN 'ADMIN';
  END IF;

  SELECT ur.role INTO v_role
  FROM public.user_roles ur
  WHERE ur.user_id = v_uid AND ur.is_active = true
  LIMIT 1;

  IF v_role IN ('DELIVERY', 'SALON') THEN
    RETURN v_role;
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_access_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_access_role() TO authenticated;
