-- Backward-compatible order RPC. Delivery continues through the existing validated function.
-- Pickup reuses its stock/accompaniment/payment validation and then stores the pickup modality.
CREATE OR REPLACE FUNCTION public.create_customer_order(
  p_order_type text,
  p_customer_name text,
  p_customer_phone text,
  p_delivery_address text,
  p_payment_method text,
  p_needs_change boolean,
  p_change_for_cents integer,
  p_items jsonb,
  p_customer_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_result jsonb;
  v_order_id uuid;
BEGIN
  IF p_order_type NOT IN ('DELIVERY', 'PICKUP') THEN
    RAISE EXCEPTION 'Modalidade de recebimento inválida.';
  END IF;

  IF p_order_type = 'DELIVERY' THEN
    IF length(trim(coalesce(p_delivery_address, ''))) < 8 OR length(p_delivery_address) > 300 THEN
      RAISE EXCEPTION 'Informe um endereço completo.';
    END IF;
    RETURN public.create_delivery_order(
      p_customer_name, p_customer_phone, p_delivery_address, p_payment_method,
      p_needs_change, p_change_for_cents, p_items, p_customer_notes
    );
  END IF;

  IF length(trim(coalesce(p_delivery_address, ''))) > 0 THEN
    RAISE EXCEPTION 'Retirada não deve conter endereço de entrega.';
  END IF;

  v_result := public.create_delivery_order(
    p_customer_name, p_customer_phone, 'RETIRADA NO LOCAL', p_payment_method,
    p_needs_change, p_change_for_cents, p_items, p_customer_notes
  );
  v_order_id := (v_result->>'order_id')::uuid;

  UPDATE public.orders
     SET order_type = 'PICKUP', delivery_address = NULL
   WHERE id = v_order_id;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.create_customer_order(text,text,text,text,text,boolean,integer,jsonb,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_customer_order(text,text,text,text,text,boolean,integer,jsonb,text) TO service_role;
